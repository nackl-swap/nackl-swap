pragma gosh-solidity >=0.76.1;
pragma AbiHeader expire;
pragma AbiHeader pubkey;

/// Spike 3: does gosh.mintshellq() add native gas in OUR DApp, and what does it take?
///
/// How sponsored gas works (dev.ackinacki.com + DappRoot.sol):
///   - Each DApp has one DappConfig holding SHELL credit (`available_balance`).
///   - It is created when the DApp's ROOT contract (self-rooted: dapp_id == account_id) sends an
///     internal message to DappRoot (0000…::9999…) calling `deployNewConfigCustom`, with >= 100 SHELL
///     attached. DappRoot burns the SHELL and credits the same amount. It takes the dapp id from
///     msg.sender, so the message must come from this contract, not from tvm-cli directly.
///   - Anyone can top up credit by sending SHELL to the DappConfig.
///   - gosh.mintshellq(x) is quiet: it never aborts. The Block Keeper applies it at block assembly,
///     so new gas shows AFTER the transaction. Read `getNative` afterwards, not within tryMint.
///
/// Expected: tryMint does nothing before the config exists, and adds ~TOPUP after.
contract Sponsor {
    uint64 constant TOPUP = 10 vmshell;

    uint128 public nativeBefore;
    uint128 public nativeAfter;
    uint32 public calls;

    constructor() {
        require(tvm.pubkey() != 0, 101);
        require(msg.pubkey() == tvm.pubkey(), 102);
        tvm.accept();
    }

    receive() external {
        tvm.accept();
    }

    function tryMint() external {
        require(msg.pubkey() == tvm.pubkey(), 102);
        tvm.accept();
        nativeBefore = address(this).balance;
        gosh.mintshellq(TOPUP);
        nativeAfter = address(this).balance;
        calls++;
    }

    /// Owner-only raw send, used to ask DappRoot to create our DappConfig.
    /// `payload` is the message body from `tvm-cli body deployNewConfigCustom ...`.
    function sendTransaction(
        address dest,
        varuint16 value,
        bool bounce,
        mapping(uint32 => varuint32) cc,
        uint16 flags,
        TvmCell payload
    ) external {
        require(msg.pubkey() == tvm.pubkey(), 102);
        tvm.accept();
        dest.transfer({value: value, bounce: bounce, flag: flags, currencies: cc, body: payload});
    }

    function getNative() external view returns (uint128) {
        return address(this).balance;
    }
}
