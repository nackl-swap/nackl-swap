pragma gosh-solidity >=0.76.1;
pragma AbiHeader expire;
pragma AbiHeader pubkey;

/// Spike 1: does SHELL (ECC[2]) sent across a DApp boundary arrive as SHELL,
/// or is it converted to native vmshell on arrival?
///
/// Deploy this (it starts its own DApp), then have the Shellnet giver send it
/// ECC with flag 1, then again with flag 16. After each transfer, read
/// `getSnapshot` and `receiptsLog`. A positive dShell means SHELL arrived as SHELL;
/// a jump in dNative with dShell == 0 means it was converted.
contract ShellProbe {
    uint32 constant NACKL = 1;
    uint32 constant SHELL = 2;

    struct Receipt {
        address from;
        int256 dNative;
        int256 dShell;
        int256 dNackl;
        uint64 at;
    }

    uint32 public receipts;
    uint128 public lastNative;
    uint128 public lastShell;
    uint128 public lastNackl;
    mapping(uint32 => Receipt) public receiptsLog;

    constructor() {
        require(tvm.pubkey() != 0, 101);
        require(msg.pubkey() == tvm.pubkey(), 102);
        tvm.accept();
        _snapshot();
    }

    receive() external {
        tvm.accept();
        _record(msg.sender);
    }

    function _record(address from) private {
        uint128 n  = address(this).balance;
        uint128 s  = uint128(address(this).currencies[SHELL]);
        uint128 nk = uint128(address(this).currencies[NACKL]);
        receiptsLog[receipts] = Receipt(
            from,
            int256(uint256(n))  - int256(uint256(lastNative)),
            int256(uint256(s))  - int256(uint256(lastShell)),
            int256(uint256(nk)) - int256(uint256(lastNackl)),
            uint64(block.timestamp)
        );
        receipts++;
        lastNative = n;
        lastShell = s;
        lastNackl = nk;
    }

    function _snapshot() private {
        lastNative = address(this).balance;
        lastShell  = uint128(address(this).currencies[SHELL]);
        lastNackl  = uint128(address(this).currencies[NACKL]);
    }

    function getSnapshot() external view returns (uint128 native, uint128 shell, uint128 nackl, uint32 count) {
        return (
            address(this).balance,
            uint128(address(this).currencies[SHELL]),
            uint128(address(this).currencies[NACKL]),
            receipts
        );
    }
}
