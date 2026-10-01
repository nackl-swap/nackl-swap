pragma gosh-solidity >=0.76.1;
pragma AbiHeader expire;
pragma AbiHeader pubkey;

import "AtomicSwap.sol";

/// SwapFactory — root of our DApp. Deploys one AtomicSwap per lot and owns the DApp's gas credit.
///
/// Flow: the maker's wallet calls createLot() with the give-currency attached (flag 1). The factory
/// checks the lot, then deploys an AtomicSwap carrying those coins (born funded) plus initial gas,
/// all in the same transaction. The factory never keeps a maker's coins.
///
/// Admin: the owner can only (a) send raw messages from the factory's own balance, used to create
/// the DappConfig and to withdraw fees, limited to ECC the factory itself holds (`_held`), and
/// (b) nothing else. Lots are immutable and hold user funds.
contract SwapFactory {
    uint16 constant ERR_NOT_OWNER   = 100;
    uint16 constant ERR_PAIR        = 101;
    uint16 constant ERR_TOO_SMALL   = 102;
    uint16 constant ERR_DEADLINE    = 103;
    uint16 constant ERR_PRICE       = 104;
    uint16 constant ERR_FEE         = 105;
    uint16 constant ERR_NOT_ARRIVED = 106;
    uint16 constant ERR_NOT_HELD    = 107;
    uint16 constant ERR_LOW_GAS     = 108;
    uint16 constant ERR_UNEXPECTED  = 109;
    uint16 constant ERR_DELAY       = 110;

    uint16 constant MAX_FEE_BPS     = 100;          // 1%, same cap as AtomicSwap
    uint64 constant MAX_TTL         = 7 days;
    uint64 constant MIN_CLOSE_DELAY = 60;           // same floor as AtomicSwap
    uint64 constant LOT_GAS         = 0.3 vmshell;  // initial gas for each lot (same DApp: arrives intact)
    uint64 constant DEPLOY_MARGIN   = 0.2 vmshell;  // plus fees, so the deploy cannot fail for gas
    uint64 constant MIN_GAS         = 5 vmshell;
    uint64 constant TOPUP           = 10 vmshell;

    uint32 constant NACKL = 1;
    uint32 constant SHELL = 2;
    uint32 constant USDC  = 3;

    TvmCell _lotCode;
    uint16  _feeBps;
    uint64  _closeDelay;
    uint64  _lots;
    uint256 _dapp;                  // our DApp id, recorded at construction
    mapping(uint32 => uint128) _minGive;
    // ECC the factory itself owns (funding, fees, gas returned by closed lots). Never a maker's coins.
    mapping(uint32 => uint128) _held;

    event LotCreated(
        uint64 nonce, address lot, address maker, uint256 makerDapp,
        uint32 giveId, uint128 giveAmount, uint32 wantId, uint128 wantAmount, uint64 deadline
    );
    event Refunded(address to, uint16 reason);

    constructor(TvmCell lotCode, uint16 feeBps, uint64 closeDelay) {
        require(tvm.pubkey() != 0, ERR_NOT_OWNER);
        require(msg.pubkey() == tvm.pubkey(), ERR_NOT_OWNER);
        require(feeBps <= MAX_FEE_BPS, ERR_FEE);
        require(closeDelay >= MIN_CLOSE_DELAY, ERR_DELAY);
        tvm.accept();
        _lotCode = lotCode;
        _feeBps = feeBps;
        _closeDelay = closeDelay;
        // Self-rooted: our DApp id IS our account id. `address(this).dapp_id` is unavailable during the
        // external deploy transaction (VM error 35 "DApp ID is not set"), and a failed constructor on
        // Acki Nacki leaves the code installed but uninitialised (every call then fails with exit 76).
        _dapp = address(this).value;
        // Minimum lot so the fee covers sponsored gas (spike 3 economics).
        _minGive[NACKL] = 1000 * 1e9;   // 1,000 NACKL (9 decimals)
        _minGive[SHELL] = 100 * 1e9;    // 100 SHELL   (9 decimals)
        _minGive[USDC]  = 1e6;          // 1 USDC      (6 decimals)
        // Funding sent before deploy never passed through receive(); count it now.
        for (uint32 id = 1; id <= 3; id++) {
            _held[id] = uint128(address(this).currencies[id]);
        }
    }

    receive() external {
        tvm.accept();                   // fees, funding and closed lots' leftovers arrive here
        // Count only what ARRIVED. SHELL sent with flag 16 is listed in msg.currencies but converted to
        // gas on arrival (spike 6 C4). Counting the listed amount let _held exceed the real balance, which
        // blocked every SHELL-giving createLot (ERR_NOT_ARRIVED) and could be triggered by anyone with a
        // 1-SHELL flag-16 transfer (docs/SECURITY_REVIEW.md F13).
        for ((uint32 id, varuint32 amount) : msg.currencies) {
            uint128 bal = uint128(address(this).currencies[id]);
            if (bal > _held[id]) {
                _held[id] += math.min(uint128(amount), bal - _held[id]);
            }
        }
    }

    /// Called by the maker's wallet with the give-currency attached (flag 1), and nothing else.
    /// `makerDapp` is the maker wallet's DApp id (contracts can read only their own).
    function createLot(uint32 giveId, uint32 wantId, uint128 wantAmount, uint64 deadline, uint256 makerDapp) external {
        // Checks before accepting gas. A refusal of a bounceable message bounces the coins back;
        // a failing NON-bounceable message is accepted and its coins refunded (_refused).
        uint128 give = uint128(msg.currencies[giveId]);
        if (_refused(_createError(giveId, wantId, wantAmount, deadline, give))) { return; }
        tvm.accept();
        _ensureGas();

        mapping(uint32 => varuint32) ecc;
        ecc[giveId] = varuint32(give);
        address lot = new AtomicSwap{
            stateInit: _stateInit(_lots), value: LOT_GAS, flag: 1, bounce: false, currencies: ecc
        }(msg.sender, makerDapp, giveId, give, wantId, wantAmount, deadline, _feeBps,
          address(this), _dapp, _closeDelay);
        emit LotCreated(_lots, lot, msg.sender, makerDapp, giveId, give, wantId, wantAmount, deadline);
        _lots++;
    }

    function _createError(uint32 giveId, uint32 wantId, uint128 wantAmount, uint64 deadline, uint128 give)
        private view returns (uint16)
    {
        if (giveId == wantId || !_minGive.exists(giveId) || !_minGive.exists(wantId)) { return ERR_PAIR; }
        for ((uint32 id, varuint32 amount) : msg.currencies) {
            if (id != giveId && amount != 0) { return ERR_UNEXPECTED; }
        }
        if (give < _minGive[giveId]) { return ERR_TOO_SMALL; }
        // The maker's coins must have ARRIVED as that currency (SHELL sent with flag 16 is converted to
        // gas on arrival; forwarding it would fail in the action phase, which aborts without a bounce).
        if (uint128(address(this).currencies[giveId]) < _held[giveId] + give) { return ERR_NOT_ARRIVED; }
        if (wantAmount == 0) { return ERR_PRICE; }
        if (deadline <= block.timestamp || deadline > block.timestamp + MAX_TTL) { return ERR_DEADLINE; }
        // Refuse rather than strand: the deploy must not fail for lack of gas.
        if (address(this).balance < LOT_GAS + DEPLOY_MARGIN) { return ERR_LOW_GAS; }
        return 0;
    }

    /// Returns true if the call failed and its coins were refunded; reverts if they will bounce back.
    /// A refused NON-bounceable message would leave its coins here, outside _held (spike 6 C8).
    function _refused(uint16 err) private returns (bool) {
        if (err == 0) { return false; }
        if (msg.isExternal || msg.currencies.empty() || _bounceable()) { revert(err); }
        tvm.accept();
        mapping(uint32 => varuint32) back;
        for ((uint32 id, varuint32 amount) : msg.currencies) {
            uint128 bal = uint128(address(this).currencies[id]);
            uint128 free = bal > _held[id] ? bal - _held[id] : 0;     // never the factory's own coins
            uint128 r = math.min(uint128(amount), free);
            if (r > 0) { back[id] = varuint32(r); }
        }
        emit Refunded(msg.sender, err);
        if (!back.empty() && address(this).balance >= DEPLOY_MARGIN) {
            msg.sender.transfer({value: 0.01 vmshell, bounce: false, flag: 1, currencies: back, dest_dapp_id: _dapp});
        }
        return true;
    }

    /// bounce bit of the inbound internal message (verified: spike 6 C1, C2).
    function _bounceable() private pure returns (bool) {
        TvmSlice s = msg.data.toSlice();
        uint8 head = s.load(uint8);
        return (head >> 5) & 1 == 1;
    }

    /// Owner-only raw send from the factory's own balance: create the DappConfig, withdraw fees.
    function sendTransaction(
        address dest, uint256 destDapp, varuint16 value, bool bounce,
        mapping(uint32 => varuint32) cc, uint16 flags, TvmCell payload
    ) external {
        require(msg.pubkey() == tvm.pubkey(), ERR_NOT_OWNER);
        // The owner can spend only what the factory itself holds, never a maker's coins.
        for ((uint32 id, varuint32 amount) : cc) {
            require(_held[id] >= uint128(amount), ERR_NOT_HELD);
        }
        tvm.accept();
        for ((uint32 id, varuint32 amount) : cc) {
            _held[id] -= uint128(amount);
        }
        dest.transfer({value: value, bounce: bounce, flag: flags, currencies: cc, body: payload, dest_dapp_id: destDapp});
    }

    function _stateInit(uint64 nonce) private view returns (TvmCell) {
        return abi.encodeStateInit({
            code: _lotCode,
            varInit: {_nonce: nonce, _factory: address(this)},
            contr: AtomicSwap
        });
    }

    function _ensureGas() private pure {
        if (address(this).balance < MIN_GAS) {
            gosh.mintshellq(TOPUP);
        }
    }

    // ---- read-only ----

    /// Account id of lot `nonce`; its canonical address is <factory dapp>::<this id>.
    function lotAccountId(uint64 nonce) external view returns (uint256) {
        return tvm.hash(_stateInit(nonce));
    }

    /// Safe for local `tvm-cli run`: no DApp-context instructions (those fail off-chain with
    /// exit code -36 "DApp ID is not set"). Read gas credit from the DappConfig's getDetails.
    function getInfo() external view returns (
        uint64 lots, uint16 feeBps, uint256 dapp, uint64 closeDelay,
        uint128 minNackl, uint128 minShell, uint128 minUsdc
    ) {
        return (_lots, _feeBps, _dapp, _closeDelay, _minGive[NACKL], _minGive[SHELL], _minGive[USDC]);
    }

    /// ECC the factory counts as its own. Must never exceed its real balance (checked by the test suite).
    function getHeld() external view returns (uint128 nackl, uint128 shell, uint128 usdc) {
        return (_held[NACKL], _held[SHELL], _held[USDC]);
    }
}
