pragma gosh-solidity >=0.76.1;
pragma AbiHeader expire;
pragma AbiHeader pubkey;

/// Spike 6: what does a PLAIN transfer (no function call) look like to the receiving contract?
/// The Acki Nacki Wallet app can only make plain transfers, so a web app built on it needs:
///   a) can the contract read the inbound message's bounce flag (from msg.data)?
///   b) SHELL sent with flag 1 vs flag 16: what is listed in msg.currencies vs what actually arrived?
///   c) when the contract refuses, does a NON-bounceable transfer strand the coins?
///   d) does a transfer with the wrong dest_dapp_id still reach an existing contract?
contract TransferProbe {
    struct Seen {
        uint8   head;           // first 8 bits of the inbound message: tag ihr_disabled bounce bounced ...
        uint128 listedNackl;
        uint128 listedShell;
        uint128 holdNackl;      // address(this).currencies during the transaction
        uint128 holdShell;
        uint128 native;
        address sender;
    }

    bool public refusing;
    uint32 public count;
    mapping(uint32 => Seen) _seen;

    constructor() {
        require(tvm.pubkey() != 0, 101);
        require(msg.pubkey() == tvm.pubkey(), 102);
        tvm.accept();
    }

    receive() external {
        require(!refusing, 300);        // compute-phase refusal, before accepting gas
        tvm.accept();
        TvmSlice s = msg.data.toSlice();
        _seen[count] = Seen(
            s.load(uint8),
            uint128(msg.currencies[1]),
            uint128(msg.currencies[2]),
            uint128(address(this).currencies[1]),
            uint128(address(this).currencies[2]),
            address(this).balance,
            msg.sender
        );
        count++;
    }

    function setRefusing(bool value) external {
        require(msg.pubkey() == tvm.pubkey(), 102);
        tvm.accept();
        refusing = value;
    }

    /// bounce = bit 5 of head, bounced = bit 4 (int_msg_info$0 ihr_disabled:Bool bounce:Bool bounced:Bool).
    function getSeen(uint32 i) external view returns (
        uint8 head, bool bounce, uint128 listedNackl, uint128 listedShell,
        uint128 holdNackl, uint128 holdShell, uint128 native, address sender
    ) {
        Seen x = _seen[i];
        return (x.head, (x.head >> 5) & 1 == 1, x.listedNackl, x.listedShell,
                x.holdNackl, x.holdShell, x.native, x.sender);
    }
}
