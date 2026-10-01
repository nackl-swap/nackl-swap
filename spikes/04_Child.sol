pragma gosh-solidity >=0.76.1;
pragma AbiHeader expire;
pragma AbiHeader pubkey;

/// Spike 4 child (stands in for an AtomicSwap lot):
///   - born funded? (records the ECC it held at construction)
///   - lives in the factory's DApp? (proved by native value arriving un-zeroed)
///   - can it mint gas from the FACTORY's DappConfig?
///       constructor mints MINT_CTOR (run 1 showed this does NOT land)
///       poke() mints MINT_POKE after tvm.accept(), triggered later by the factory
///     Different amounts so we can tell which mint landed. Credit lands after the tx.
contract Child {
    uint64 constant MINT_CTOR = 2 vmshell;
    uint64 constant MINT_POKE = 3 vmshell;

    uint64 static _nonce;
    address static _factory;

    uint128 public shellAtBirth;
    uint128 public nacklAtBirth;
    uint128 public nativeAtBirth;
    uint32 public pokes;
    uint128 public nativeAtLastPoke;

    constructor() {
        require(msg.sender == _factory, 101);
        shellAtBirth  = uint128(address(this).currencies[2]);
        nacklAtBirth  = uint128(address(this).currencies[1]);
        nativeAtBirth = address(this).balance;
        gosh.mintshellq(MINT_CTOR);
    }

    /// The pattern a real lot uses inside take(): accept, then top up gas from our DApp credit.
    function poke() external {
        require(msg.sender == _factory, 102);
        tvm.accept();
        nativeAtLastPoke = address(this).balance;
        gosh.mintshellq(MINT_POKE);
        pokes++;
    }
}
