pragma gosh-solidity >=0.76.1;
pragma AbiHeader expire;
pragma AbiHeader pubkey;

/// Test-only user wallet (maker / taker). Self-rooted, so it lives in its own DApp, like a real
/// user's Hot wallet. It can send any message with currencies and a body, and can be told to
/// reject incoming transfers to force a bounced payout.
contract TestWallet {
    bool public rejecting;
    uint32 public bounces;

    constructor() {
        require(tvm.pubkey() != 0, 101);
        require(msg.pubkey() == tvm.pubkey(), 102);
        tvm.accept();
    }

    receive() external {
        require(!rejecting, 300);       // checked before accepting gas
        tvm.accept();
    }

    onBounce(TvmSlice /* body */) external {
        tvm.accept();
        bounces++;
    }

    function setRejecting(bool value) external {
        require(msg.pubkey() == tvm.pubkey(), 102);
        tvm.accept();
        rejecting = value;
    }

    function sendTx(
        address dest, uint256 destDapp, varuint16 value, bool bounce,
        mapping(uint32 => varuint32) cc, uint16 flags, TvmCell payload
    ) external view {
        require(msg.pubkey() == tvm.pubkey(), 102);
        tvm.accept();
        dest.transfer({value: value, bounce: bounce, flag: flags, currencies: cc, body: payload, dest_dapp_id: destDapp});
    }

    function myDapp() external pure returns (uint256) {
        return address(this).value;     // self-rooted: DApp id == account id
    }
}
