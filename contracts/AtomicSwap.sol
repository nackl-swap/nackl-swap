pragma gosh-solidity >=0.76.1;
pragma AbiHeader expire;
pragma AbiHeader pubkey;

/// AtomicSwap — one immutable, non-custodial lot. FIXED price.
///
/// Invariants (docs/CONTRACT_PLAN.md):
///   I1 exists iff funded from birth      I2 funds leave only to maker / taker / treasury (fee ≤ 1%)
///   I3 fills at most once                I4 every incoming coin is used once or returned
///   I5 an open lot can always be reclaimed to its maker   I6 no admin, no upgrade
///
/// Rules verified on Shellnet (spikes/RESULTS.md, tests/RESULTS.md):
///   - Payouts use flag 1 (flag 16 would turn SHELL into gas) and go only to addresses this contract
///     recorded (maker at birth, taker = msg.sender, treasury).
///   - A bounced payout returns its ECC in full; it is booked in _owed and paid out by claim()/release().
///   - Gas: the factory funds initial gas at deploy; later calls top up with accept + mintshellq.
///     Never mint in the constructor.
///   - A contract can read only its own DApp id, so users pass theirs (makerDapp / takerDapp).
///     Existing accounts are reached by account id even with another DApp id (Phase 1 T8, spike 6 C6).
///   - Every failure must happen in the compute phase (require), never in the action phase:
///     compute failures bounce the incoming coins, action failures abort without a bounce.
///   - Accept only the expected currency (docs/SECURITY_REVIEW.md F3).
///   - A refused NON-bounceable message leaves its coins here (spike 6 C8). So a failing call that carries
///     coins in a non-bounceable message is accepted and the coins that arrived are refunded (_refused).
///
/// Wallet-app flows (docs/WALLET_INTEGRATION.md): the Acki Nacki Wallet can only make plain transfers.
///   - Pay-to-take: a plain transfer of the want currency to an open lot fills it, like take().
///   - reclaim() after the deadline, close() and release() need no wallet: anyone may send them,
///     including as unsigned external messages. Coins still go only to their recorded owners.
contract AtomicSwap {
    uint16 constant ERR_NOT_FACTORY  = 200;
    uint16 constant ERR_NOT_OPEN     = 201;
    uint16 constant ERR_EXPIRED      = 202;
    uint16 constant ERR_UNDERPAID    = 203;
    uint16 constant ERR_NOT_ALLOWED  = 204;
    uint16 constant ERR_NOTHING_OWED = 205;
    uint16 constant ERR_BAD_PARAMS   = 206;
    uint16 constant ERR_NOT_ARRIVED  = 207;
    uint16 constant ERR_LOW_GAS      = 208;
    uint16 constant ERR_UNEXPECTED   = 209;
    uint16 constant ERR_TOO_EARLY    = 210;
    uint16 constant ERR_NOT_EMPTY    = 211;

    uint16  constant MAX_FEE_BPS     = 100;          // hard cap: 1%
    uint64  constant MIN_CLOSE_DELAY = 60;           // seconds; bounces return within seconds
    uint64  constant MIN_GAS         = 0.2 vmshell;  // top up when below this
    uint64  constant TOPUP           = 0.5 vmshell;
    uint64  constant PAYOUT_GAS      = 0.1 vmshell;  // enough native gas for 3 payouts + event
    uint64  constant MSG_VALUE       = 0.01 vmshell; // attached to payouts; zeroed when crossing DApps

    uint8 constant OPEN      = 0;
    uint8 constant FILLED    = 1;
    uint8 constant RECLAIMED = 2;

    // Identity: address = hash(code, factory, nonce).
    address static _factory;
    uint64  static _nonce;

    // Terms, fixed by the constructor.
    address _maker;     uint256 _makerDapp;
    uint32  _giveId;    uint128 _giveAmount;
    uint32  _wantId;    uint128 _wantAmount;
    uint64  _deadline;  uint16  _feeBps;
    address _treasury;  uint256 _treasuryDapp;
    uint64  _closeDelay;

    // Lifecycle.
    uint8   _state;
    address _taker;     uint256 _takerDapp;
    uint128 _fee;
    uint64  _settledAt;

    // Coins held for their owners (bounced payouts, deferred refunds): owner -> currency -> amount.
    mapping(address => mapping(uint32 => uint128)) _owed;
    mapping(uint32 => uint128) _owedTotal;          // per currency; never refunded to anyone else

    event Filled(address taker, uint128 paid, uint128 fee);
    event Reclaimed(address maker, address by);
    event PayoutBounced(address to, uint32 currency, uint128 amount);
    event Refunded(address to, uint16 reason);
    event Claimed(address owner, address by);
    event Closed(address by);

    constructor(
        address maker, uint256 makerDapp,
        uint32 giveId, uint128 giveAmount,
        uint32 wantId, uint128 wantAmount,
        uint64 deadline, uint16 feeBps,
        address treasury, uint256 treasuryDapp,
        uint64 closeDelay
    ) {
        // MUST NOT FAIL in practice: on Acki Nacki a failed constructor leaves the code installed and
        // uninitialised, with the maker's coins inside and every call reverting (exit 76). SwapFactory
        // validates every condition below before deploying; these requires are a second line only.
        require(msg.sender == _factory, ERR_NOT_FACTORY);
        require(feeBps <= MAX_FEE_BPS && giveId != wantId && wantAmount > 0 && giveAmount > 0
                && closeDelay >= MIN_CLOSE_DELAY, ERR_BAD_PARAMS);
        // I1: the factory attached the maker's coins to the deploy message.
        require(uint128(address(this).currencies[giveId]) >= giveAmount, ERR_BAD_PARAMS);
        _maker = maker;         _makerDapp = makerDapp;
        _giveId = giveId;       _giveAmount = giveAmount;
        _wantId = wantId;       _wantAmount = wantAmount;
        _deadline = deadline;   _feeBps = feeBps;
        _treasury = treasury;   _treasuryDapp = treasuryDapp;
        _closeDelay = closeDelay;
        _state = OPEN;
    }

    /// Taker attaches at least `wantAmount` of the want currency (flag 1), and nothing else.
    /// `takerDapp` is the taker wallet's DApp id.
    function take(uint256 takerDapp) external {
        uint128 paid = uint128(msg.currencies[_wantId]);
        if (_refused(_takeError(paid))) { return; }
        tvm.accept();
        _ensureGas();
        _fill(msg.sender, takerDapp, paid);
    }

    /// Pay-to-take: a plain transfer of the want currency (all the Acki Nacki Wallet app can send)
    /// fills the lot exactly like take(). The give currency goes back to the sender's account.
    receive() external {
        uint128 paid = uint128(msg.currencies[_wantId]);
        if (_refused(_takeError(paid))) { return; }
        tvm.accept();
        _ensureGas();
        _fill(msg.sender, _treasuryDapp, paid);          // the sender exists: routed by account id
    }

    /// Return the coins to the recorded maker. The maker may call it any time the lot is open;
    /// after the deadline anyone may, including by external message (I5).
    function reclaim() external {
        uint16 err = 0;
        if (msg.sender != _maker && block.timestamp < _deadline) { err = ERR_NOT_ALLOWED; }
        else if (_state != OPEN) { err = ERR_NOT_OPEN; }
        else if (!msg.currencies.empty()) { err = ERR_UNEXPECTED; }
        if (_refused(err)) { return; }
        tvm.accept();
        _ensureGas();
        _state = RECLAIMED;
        _settledAt = uint64(block.timestamp);
        _pay(_maker, _makerDapp, _giveId, _giveAmount, 0, 0);
        emit Reclaimed(_maker, msg.sender);
    }

    /// Collect coins held for the caller. `myDapp` is the caller's DApp id.
    function claim(uint256 myDapp) external {
        uint16 err = 0;
        if (!msg.currencies.empty()) { err = ERR_UNEXPECTED; }
        else if (!_hasOwed(msg.sender)) { err = ERR_NOTHING_OWED; }
        if (_refused(err)) { return; }
        tvm.accept();
        _ensureGas();
        _payOwed(msg.sender, myDapp);
    }

    /// Anyone (no wallet needed: external message) may push coins held for `owner` to `owner`.
    /// For owners whose wallet cannot call claim(), such as the Acki Nacki Wallet app.
    function release(address owner) external {
        uint16 err = 0;
        if (!msg.currencies.empty()) { err = ERR_UNEXPECTED; }
        else if (!_hasOwed(owner)) { err = ERR_NOTHING_OWED; }
        if (_refused(err)) { return; }
        tvm.accept();
        _ensureGas();
        uint256 dapp = owner == _maker ? _makerDapp : (owner == _taker ? _takerDapp : _treasuryDapp);
        _payOwed(owner, dapp);
    }

    /// Delete a settled, empty lot and return its leftover gas to the factory (docs/SECURITY_REVIEW.md F1).
    /// Anyone may call it, including by external message. Waits `closeDelay` after settlement so any
    /// bounced payout has already come back (a bounce to a deleted account would be lost).
    function close() external {
        uint16 err = 0;
        if (!msg.currencies.empty()) { err = ERR_UNEXPECTED; }
        else if (_state == OPEN) { err = ERR_NOT_OPEN; }
        else if (block.timestamp < _settledAt + _closeDelay) { err = ERR_TOO_EARLY; }
        else if (uint128(address(this).currencies[_giveId]) != 0
                 || uint128(address(this).currencies[_wantId]) != 0 || _anyOwed()) { err = ERR_NOT_EMPTY; }
        if (_refused(err)) { return; }
        tvm.accept();
        emit Closed(msg.sender);
        _factory.transfer({value: 0, bounce: false, flag: 128 + 32});   // carry all, then delete
    }

    /// A payout bounced. Its ECC came back in full; book it for the recipient (I4).
    /// Payouts are distinguishable by what they carry: only the taker's includes the give currency;
    /// the maker's and treasury's carry only the want currency, in different amounts.
    /// (Refunds and owed payouts are sent non-bounceable, so they never come back here.)
    onBounce(TvmSlice /* body */) external {
        tvm.accept();
        uint128 give = uint128(msg.currencies[_giveId]);
        uint128 want = uint128(msg.currencies[_wantId]);
        if (give == 0 && want == 0) { return; }
        address to;
        if (_state == RECLAIMED) {
            to = _maker;
        } else if (give > 0) {
            to = _taker;
        } else if (_fee > 0 && want == _fee && want != _wantAmount - _fee) {
            to = _treasury;
        } else if (want == _wantAmount - _fee) {
            to = _maker;
        } else {
            to = _taker;
        }
        if (give > 0) { _book(to, _giveId, give); emit PayoutBounced(to, _giveId, give); }
        if (want > 0) { _book(to, _wantId, want); emit PayoutBounced(to, _wantId, want); }
    }

    // ---- internals ----

    function _takeError(uint128 paid) private view returns (uint16) {
        if (_state != OPEN) { return ERR_NOT_OPEN; }
        if (block.timestamp >= _deadline) { return ERR_EXPIRED; }
        for ((uint32 id, varuint32 amount) : msg.currencies) {
            if (id != _wantId && amount != 0) { return ERR_UNEXPECTED; }
        }
        if (paid < _wantAmount) { return ERR_UNDERPAID; }
        // The coins must have ARRIVED as that currency, not just be listed. SHELL sent with flag 16 is
        // listed but converted to gas on arrival (spike 6 C4); paying it out would fail in the action
        // phase, which aborts WITHOUT a bounce (Phase 1 run 3).
        if (uint128(address(this).currencies[_wantId]) < paid + _owedTotal[_wantId]) { return ERR_NOT_ARRIVED; }
        if (address(this).balance < PAYOUT_GAS) { return ERR_LOW_GAS; }
        return 0;
    }

    /// Returns true if the call failed and its coins were refunded; reverts if they will bounce back.
    function _refused(uint16 err) private returns (bool) {
        if (err == 0) { return false; }
        // External, coin-less, or bounceable: refuse in the compute phase. A bounce returns the coins
        // untouched, flag-16 SHELL included, as SHELL (spike 6 C7, C9).
        if (msg.isExternal || msg.currencies.empty() || _bounceable()) { revert(err); }
        // Non-bounceable with coins: refusing would strand them here (spike 6 C8). Accept and return
        // what actually arrived. (Flag-16 SHELL became gas on arrival and cannot be returned: C10.)
        tvm.accept();
        _ensureGas();
        _refund(err);
        return true;
    }

    /// bounce bit of the inbound internal message: int_msg_info$0 ihr_disabled:Bool bounce:Bool bounced:Bool.
    /// Verified on Shellnet: 0110.... when bounceable, 0100.... when not (spike 6 C1, C2).
    function _bounceable() private pure returns (bool) {
        TvmSlice s = msg.data.toSlice();
        uint8 head = s.load(uint8);
        return (head >> 5) & 1 == 1;
    }

    /// Return to msg.sender the coins of this message that are really here and belong to no one else.
    function _refund(uint16 reason) private {
        mapping(uint32 => varuint32) back;
        for ((uint32 id, varuint32 amount) : msg.currencies) {
            uint128 held = uint128(address(this).currencies[id]);
            uint128 reserved = _owedTotal[id];
            if (_state == OPEN && id == _giveId) { reserved += _giveAmount; }
            uint128 free = held > reserved ? held - reserved : 0;
            uint128 r = math.min(uint128(amount), free);
            if (r > 0) { back[id] = varuint32(r); }
        }
        emit Refunded(msg.sender, reason);
        if (back.empty()) { return; }
        if (address(this).balance < PAYOUT_GAS) {
            // Not enough gas to send safely now: hold it for the sender (release() later).
            for ((uint32 id, varuint32 amount) : back) { _book(msg.sender, id, uint128(amount)); }
            return;
        }
        // Non-bounceable: the sender exists, and if it refuses, the coins stay in its own account.
        msg.sender.transfer({value: MSG_VALUE, bounce: false, flag: 1, currencies: back, dest_dapp_id: _treasuryDapp});
    }

    function _fill(address taker, uint256 takerDapp, uint128 paid) private {
        _state = FILLED;                                  // I3: before any send
        _settledAt = uint64(block.timestamp);
        _taker = taker;
        _takerDapp = takerDapp;
        _fee = math.muldiv(_wantAmount, _feeBps, 10000);
        uint128 toMaker = _wantAmount - _fee;
        uint128 change = paid - _wantAmount;

        _pay(_maker, _makerDapp, _wantId, toMaker, 0, 0);
        if (_fee > 0) {
            _pay(_treasury, _treasuryDapp, _wantId, _fee, 0, 0);
        }
        _pay(_taker, _takerDapp, _giveId, _giveAmount, _wantId, change);  // coins + change together
        emit Filled(taker, paid, _fee);
    }

    function _book(address owner, uint32 id, uint128 amount) private {
        _owed[owner][id] += amount;
        _owedTotal[id] += amount;
    }

    function _hasOwed(address owner) private view returns (bool) {
        optional(mapping(uint32 => uint128)) m = _owed.fetch(owner);
        if (!m.hasValue()) { return false; }
        for ((, uint128 amount) : m.get()) {
            if (amount > 0) { return true; }
        }
        return false;
    }

    function _anyOwed() private view returns (bool) {
        for ((, uint128 amount) : _owedTotal) {
            if (amount > 0) { return true; }
        }
        return false;
    }

    /// Pay everything held for `owner`, non-bounceable: the owner's account exists and a refusal leaves
    /// the coins in it (spike 6 C8), so owed coins can never return and be booked or paid twice.
    function _payOwed(address owner, uint256 dapp) private {
        mapping(uint32 => varuint32) ecc;
        for ((uint32 id, uint128 amount) : _owed[owner]) {
            if (amount > 0) {
                ecc[id] = varuint32(amount);
                _owedTotal[id] -= amount;
            }
        }
        delete _owed[owner];
        owner.transfer({value: MSG_VALUE, bounce: false, flag: 1, currencies: ecc, dest_dapp_id: dapp});
        emit Claimed(owner, msg.sender);
    }

    function _pay(address to, uint256 dapp, uint32 idA, uint128 amtA, uint32 idB, uint128 amtB) private pure {
        mapping(uint32 => varuint32) ecc;
        if (amtA > 0) { ecc[idA] = varuint32(amtA); }
        if (amtB > 0) { ecc[idB] = varuint32(amtB); }
        to.transfer({value: MSG_VALUE, bounce: true, flag: 1, currencies: ecc, dest_dapp_id: dapp});
    }

    function _ensureGas() private pure {
        if (address(this).balance < MIN_GAS) {
            gosh.mintshellq(TOPUP);
        }
    }

    // ---- read-only ----

    function getTerms() external view returns (
        address maker, uint256 makerDapp, uint32 giveId, uint128 giveAmount,
        uint32 wantId, uint128 wantAmount, uint64 deadline, uint16 feeBps
    ) {
        return (_maker, _makerDapp, _giveId, _giveAmount, _wantId, _wantAmount, _deadline, _feeBps);
    }

    function getStatus() external view returns (
        uint8 state, address taker, uint256 takerDapp, uint128 fee,
        uint128 holdGive, uint128 holdWant, uint128 native
    ) {
        return (
            _state, _taker, _takerDapp, _fee,
            uint128(address(this).currencies[_giveId]),
            uint128(address(this).currencies[_wantId]),
            address(this).balance
        );
    }

    function getTimes() external view returns (uint64 deadline, uint64 settledAt, uint64 closeDelay) {
        return (_deadline, _settledAt, _closeDelay);
    }

    function getOwed(address owner) external view returns (uint128 give, uint128 want) {
        return (_owed[owner][_giveId], _owed[owner][_wantId]);
    }

    function getOwedTotal() external view returns (uint128 give, uint128 want) {
        return (_owedTotal[_giveId], _owedTotal[_wantId]);
    }
}
