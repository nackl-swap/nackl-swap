pragma gosh-solidity >=0.76.1;
pragma AbiHeader expire;
pragma AbiHeader pubkey;

/// Spike 2 helper: rejects every plain transfer, forcing a bounce.
contract Rejector {
    constructor() {
        require(tvm.pubkey() != 0, 101);
        require(msg.pubkey() == tvm.pubkey(), 102);
        tvm.accept();
    }

    receive() external {
        require(false, 777);
    }
}
