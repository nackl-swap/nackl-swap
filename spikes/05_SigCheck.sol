pragma gosh-solidity >=0.76.1;
pragma AbiHeader expire;
pragma AbiHeader pubkey;

/// Spike 5 (low risk): verify an off-chain ed25519 signature over the exact quote hash
/// the swap would use for gasless haggling. Both functions are read-only (use `tvm-cli run`).
contract SigCheck {
    constructor() {
        require(tvm.pubkey() != 0, 101);
        require(msg.pubkey() == tvm.pubkey(), 102);
        tvm.accept();
    }

    function quoteHash(address lot, address taker, uint128 price, uint64 expiry, uint64 nonce)
        external pure returns (uint256)
    {
        return tvm.hash(abi.encode(lot, taker, price, expiry, nonce));
    }

    function verify(uint256 dataHash, uint256 sigHigh, uint256 sigLow, uint256 pubkey)
        external pure returns (bool)
    {
        return tvm.checkSign(dataHash, sigHigh, sigLow, pubkey);
    }
}
