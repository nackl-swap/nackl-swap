pragma gosh-solidity >=0.76.1;
pragma AbiHeader expire;
pragma AbiHeader pubkey;

/// Spike 2: when a message carrying SHELL bounces, does the SHELL come back?
///
/// Fund this from the giver, then call `sendBouncing` twice:
///   a) dest = a deployed Rejector (reverts in receive)
///   b) dest = an address that was never deployed
/// Compare `shellBeforeSend` with `shellAfterBounce`.
///   equal            -> ECC is returned on bounce
///   lower by amount  -> ECC is NOT returned; the swap must refund explicitly
contract BounceProbe {
    uint32 constant SHELL = 2;

    uint128 public shellBeforeSend;
    uint128 public shellAfterBounce;
    uint128 public nativeAfterBounce;
    uint32 public bounces;

    constructor() {
        require(tvm.pubkey() != 0, 101);
        require(msg.pubkey() == tvm.pubkey(), 102);
        tvm.accept();
    }

    receive() external {
        tvm.accept();
    }

    function sendBouncing(address dest, uint128 shellAmount, uint16 flag) external {
        require(msg.pubkey() == tvm.pubkey(), 102);
        tvm.accept();
        shellBeforeSend = uint128(address(this).currencies[SHELL]);
        mapping(uint32 => varuint32) ecc;
        ecc[SHELL] = varuint32(shellAmount);
        dest.transfer({value: 0.1 vmshell, bounce: true, flag: flag, currencies: ecc});
    }

    onBounce(TvmSlice /* body */) external {
        tvm.accept();
        bounces++;
        shellAfterBounce = uint128(address(this).currencies[SHELL]);
        nativeAfterBounce = address(this).balance;
    }

    function getShell() external view returns (uint128) {
        return uint128(address(this).currencies[SHELL]);
    }
}
