pragma gosh-solidity >=0.76.1;
pragma AbiHeader expire;
pragma AbiHeader pubkey;

import "04_Child.sol";

/// Spike 4: the real architecture in miniature.
///   - Factory is self-rooted, so it is the ROOT of our DApp and can create our DappConfig
///     (via `sendTransaction` to DappRoot, like spike 3's Sponsor).
///   - Children it deploys join our DApp (address <factory_dapp>::<hash>), are born funded
///     with ECC, and mint their own gas from our DappConfig.
contract Factory {
    TvmCell _childCode;
    uint64 public deployed;

    constructor(TvmCell childCode) {
        require(tvm.pubkey() != 0, 101);
        require(msg.pubkey() == tvm.pubkey(), 102);
        tvm.accept();
        _childCode = childCode;
    }

    receive() external {
        tvm.accept();
    }

    function _stateInit(uint64 nonce) private view returns (TvmCell) {
        return abi.encodeStateInit({
            code: _childCode,
            varInit: {_nonce: nonce, _factory: address(this)},
            contr: Child
        });
    }

    function deployChild(uint128 shellAmount, uint128 nacklAmount) external returns (address child) {
        require(msg.pubkey() == tvm.pubkey(), 102);
        tvm.accept();
        mapping(uint32 => varuint32) ecc;
        if (shellAmount > 0) { ecc[2] = varuint32(shellAmount); }
        if (nacklAmount > 0) { ecc[1] = varuint32(nacklAmount); }
        child = new Child{stateInit: _stateInit(deployed), value: 1 vmshell, flag: 1, bounce: false, currencies: ecc}();
        deployed++;
    }

    /// Owner-only: ask child `nonce` to mint gas from our DappConfig (spike 4b).
    function pokeChild(uint64 nonce) external view {
        require(msg.pubkey() == tvm.pubkey(), 102);
        tvm.accept();
        address child = address.makeAddrStd(0, tvm.hash(_stateInit(nonce)));
        Child(child).poke{value: 0.1 vmshell, flag: 1, bounce: true}();
    }

    /// Account id of child `nonce` (the hash half of its canonical address).
    function childAccountId(uint64 nonce) external view returns (uint256) {
        return tvm.hash(_stateInit(nonce));
    }

    /// Owner-only raw send, used to ask DappRoot to create our DappConfig.
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
}
