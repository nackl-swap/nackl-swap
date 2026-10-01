pragma gosh-solidity >=0.76.1;
pragma AbiHeader expire;
pragma AbiHeader pubkey;

/// AtomicSwap — one immutable, non-custodial lot. Phase 1: FIXED price.
///
/// Invariants (docs/CONTRACT_PLAN.md):
///   I1 exists iff funded from birth      I2 funds leave only to maker / taker / treasury (fee ≤ 1%)
///   I3 fills at most once                I4 every incoming coin is used once or returned
///   I5 an open lot can always be reclaimed to its maker   I6 no admin, no upgrade
///
/// Rules verified on Shellnet (spikes/RESULTS.md, tests/RESULTS.md):
///   - Payouts use flag 1 (flag 16 would turn SHELL into gas), bounce: true, and go only to addresses
///     this contract recorded (maker at birth, taker = msg.sender).
///   - A bounced payout returns its ECC in full; it is booked in _owed and collected with claim().
///   - Gas: the factory funds initial gas at deploy; later calls top up with accept + mintshellq.
///     Never mint in the constructor.
///   - A contract can read only its own DApp id, so users pass theirs (makerDapp / takerDapp).
///   - Every failure must happen in the compute phase (require), never in the action phase:
///     compute failures bounce the incoming coins, action failures abort without a bounce.
///   - Accept only the expected currency; refuse anything else before accepting (docs/SECURITY_REVIEW.md F3).
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

    // Payouts that bounced, waiting for their owner: owner -> currency -> amount.
    mapping(address => mapping(uint32 => uint128)) _owed;

    event Filled(address taker, uint128 paid, uint128 fee);
    event Reclaimed(address maker, address by);
    event PayoutBounced(address to, uint32 currency, uint128 amount);
    event Claimed(address owner);
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
        // Cheap checks before accepting gas. If any fails, the call aborts and a bounceable
        // message returns the taker's coins (spike 2).
        require(_state == OPEN, ERR_NOT_OPEN);
        require(block.timestamp < _deadline, ERR_EXPIRED);
        for ((uint32 id, varuint32 amount) : msg.currencies) {
            require(id == _wantId || amount == 0, ERR_UNEXPECTED);
        }
        uint128 paid = uint128(msg.currencies[_wantId]);
        require(paid >= _wantAmount, ERR_UNDERPAID);
        // The coins must have ARRIVED as that currency, not just be listed in the message. SHELL sent
        // with flag 16 still shows in msg.currencies but is converted to native gas on arrival.
        // Paying it out would then fail in the action phase, and on Acki Nacki an action-phase failure
        // aborts WITHOUT a bounce, stranding the coins (Phase 1 run 3, T5). A failed require here is a
        // compute-phase failure, which bounces the coins back.
        require(uint128(address(this).currencies[_wantId]) >= paid, ERR_NOT_ARRIVED);
        // Same reason: refuse now if there is not enough gas to send the payouts.
        require(address(this).balance >= PAYOUT_GAS, ERR_LOW_GAS);
        tvm.accept();
        _ensureGas();

        _state = FILLED;                                  // I3: before any send
        _settledAt = uint64(block.timestamp);
        _taker = msg.sender;
        _takerDapp = takerDapp;
        _fee = math.muldiv(_wantAmount, _feeBps, 10000);
        uint128 toMaker = _wantAmount - _fee;
        uint128 change = paid - _wantAmount;

        _pay(_maker, _makerDapp, _wantId, toMaker, 0, 0);
        if (_fee > 0) {
            _pay(_treasury, _treasuryDapp, _wantId, _fee, 0, 0);
        }
        _pay(_taker, _takerDapp, _giveId, _giveAmount, _wantId, change);  // coins + change together
        emit Filled(msg.sender, paid, _fee);
    }

    /// Return the coins to the recorded maker. The maker may call it any time the lot is open;
    /// after the deadline anyone may (I5: an expired lot never depends on the maker acting).
    function reclaim() external {
        require(msg.sender == _maker || block.timestamp >= _deadline, ERR_NOT_ALLOWED);
        require(_state == OPEN, ERR_NOT_OPEN);
        require(msg.currencies.empty(), ERR_UNEXPECTED);
        tvm.accept();
        _ensureGas();
        _state = RECLAIMED;
        _settledAt = uint64(block.timestamp);
        _pay(_maker, _makerDapp, _giveId, _giveAmount, 0, 0);
        emit Reclaimed(_maker, msg.sender);
    }

    /// Collect a payout that bounced. `myDapp` is the caller's DApp id.
    function claim(uint256 myDapp) external {
        require(msg.currencies.empty(), ERR_UNEXPECTED);
        uint128 g = _owed[msg.sender][_giveId];
        uint128 w = _owed[msg.sender][_wantId];
        require(g > 0 || w > 0, ERR_NOTHING_OWED);
        tvm.accept();
        _ensureGas();
        delete _owed[msg.sender];
        _pay(msg.sender, myDapp, _giveId, g, _wantId, w);
        emit Claimed(msg.sender);
    }

    /// Delete a settled, empty lot and return its leftover gas to the factory (docs/SECURITY_REVIEW.md F1).
    /// Anyone may call it. Waits `closeDelay` after settlement so any bounced payout has already come
    /// back (a bounce to a deleted account would be lost). Zero give/want balance means nothing is owed.
    function close() external {
        require(msg.currencies.empty(), ERR_UNEXPECTED);
        require(_state != OPEN, ERR_NOT_OPEN);
        require(block.timestamp >= _settledAt + _closeDelay, ERR_TOO_EARLY);
        require(uint128(address(this).currencies[_giveId]) == 0
                && uint128(address(this).currencies[_wantId]) == 0, ERR_NOT_EMPTY);
        tvm.accept();
        emit Closed(msg.sender);
        _factory.transfer({value: 0, bounce: false, flag: 128 + 32});   // carry all, then delete
    }

    /// A payout bounced. Its ECC came back in full; book it for the recipient (I4).
    /// Payouts are distinguishable by what they carry: only the taker's includes the give currency;
    /// the maker's and treasury's carry only the want currency, in different amounts.
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
            to = _taker;                                  // a claim() payout to the taker
        }
        if (give > 0) { _owed[to][_giveId] += give; emit PayoutBounced(to, _giveId, give); }
        if (want > 0) { _owed[to][_wantId] += want; emit PayoutBounced(to, _wantId, want); }
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
}
