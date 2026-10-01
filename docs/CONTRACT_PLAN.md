# Contract Plan — AtomicSwap

## Invariants (every test and review checks these)

| # | Invariant |
|---|---|
| I1 | A lot contract exists **iff** it held `giveAmount` from birth (born funded). |
| I2 | Funds leave only to **maker**, **taker**, or **treasury** (fee ≤ `MAX_FEE_BPS`, fixed at deploy). |
| I3 | A lot fills **at most once** (or up to `giveAmount` in total if partial fills are added). |
| I4 | Every incoming coin is either used in exactly one fill or **refunded to its sender**. |
| I5 | After the deadline the maker can **always** reclaim, even if our servers are down. |
| I6 | `AtomicSwap` has **no admin function and no upgrade path**. |

## Architecture

```
SwapFactory  (self-rooted: starts our DApp ID; holds AtomicSwap code; DApp config for gas)
   │  internal deploy → children join our DApp ID
   ▼
AtomicSwap   (one per lot; all parameters static; address computable before deploy)
```

Off-chain: REST API + Postgres (lots, deals, depth), chain watcher (GraphQL polling),
frontend with bee SDK wallet connect.

## AtomicSwap interface (design sketch, not compiled)

```solidity
contract AtomicSwap {
    address static _factory;   address static _maker;
    uint32  static _giveId;    uint128 static _giveAmount;
    uint32  static _wantId;    uint8   static _mode;        // FIXED | DROP
    uint128 static _priceStart; uint128 static _priceFloor;  // want per give, fixed-point
    uint64  static _startAt;   uint64  static _duration;     // DROP curve
    uint64  static _deadline;  uint16  static _feeBps;       // ≤ MAX_FEE_BPS
    uint64  static _nonce;

    enum State { Open, Filled, Reclaimed }
    State _state;
    mapping(address => mapping(uint32 => uint128)) _claimable;   // bounced payouts

    function currentPrice() public view returns (uint128);
    function take() external;                                     // taker attaches want-currency
    function takeQuoted(TvmCell quote, uint256 sigHigh, uint256 sigLow) external; // v1.1
    function reclaim() external;                                  // maker only
    function claim(uint32 currencyId) external;                   // pull fallback
    onBounce(TvmSlice body) external;
}
```

## Behaviours

- **Underpaid / already filled / wrong currency** → refund explicitly, no state change
  (don't rely on revert to return ECC — spike 2 decides).
- **Overpaid** → fill and refund the difference in the same call.
- **Concurrent takers** → per-account sequential processing; first fills, second refunded.
  After the first fill, track owed amounts explicitly; never infer ownership from raw balance.
- **Payout bounces** → record in `_claimable`; owner pulls with `claim()`.
- **After settlement** → self-destruct, returning leftover native gas.

## Features

- **Drop lots:** `currentPrice()` decays linearly from `_priceStart` to `_priceFloor` over
  `_duration` using `block.timestamp`. Taker sends ≥ current price; excess refunded.
- **Gasless haggling:** negotiation off-chain; maker signs `{lot, taker, price, expiry, nonce}`;
  `takeQuoted()` verifies with `tvm.checkSign`. One-time, taker-bound, expiring.
- **Private lots:** a taker-bound quote *is* a private lot.
- **Sponsored gas:** `gosh.mintshellq()` from our DApp's credit (needs DApp config — spike 3).

## Threats

| Threat | Mitigation |
|---|---|
| Credit-pool drain (cross-DApp calls carry no native value) | Cheap rejects before `tvm.accept()`, require attached currency, minimum notionals, monitor burn |
| Quote replay | Bind to lot + taker + nonce + expiry; mark used |
| Phantom lots | Born funded (I1) |
| SHELL converting to native on arrival | Spike 1; fall back to NACKL↔USDC |
| Decimal rounding (9 vs 6) | Fixed-point, always round in the lot's favour |
| Permanent bugs | Invariant tests, Shellnet, low mainnet caps (`MAX_LOT_NOTIONAL`) |
| Drop-auction reordering by block producers | Disclose; consider commit window in v2 |

## Verified on Shellnet (Phase 0) — rules the contract must follow

| Rule | Evidence |
|---|---|
| Pay out SHELL with **flag 1**; flag 16 converts SHELL to gas | Spike 1 |
| In `take()`, read payment with `msg.currencies[id]`; if SHELL arrived as gas (sender used flag 16), refund instead of filling | Spike 1; DappRoot uses `msg.currencies` |
| Send payouts with `bounce: true`, only to addresses the contract recorded (maker at deploy, taker = `msg.sender`) | Spike 2 (bounces return ECC; a live wrong address silently keeps funds) |
| Keep `_claimable` for bounced payouts; keep explicit refunds as defence in depth | Spike 2 |
| Factory is the DApp root and creates the DappConfig (≥ 100 SHELL via DappRoot `deployNewConfigCustom`) | Spikes 3–4 |
| Factory gives each lot its initial gas via `value` at deploy (same DApp, arrives intact) | Spike 4 |
| Lots top up gas with `tvm.accept(); gosh.mintshellq(x)` in later calls; **never mint in the constructor** | Spike 4 |
| Lots are born funded: attach the maker's ECC to `new AtomicSwap{…, currencies}` | Spike 4 |
| Minimum lot ≈ 1,000 NACKL (or a flat fee) so fees exceed sponsored gas (full swap ≈ 0.03 SHELL, est.) | Spike 3 costs |
| **Fail only in the compute phase.** Action-phase failures abort without a bounce and strand coins | Phase 1 run 3 |
| Before accepting: coins actually arrived (`address(this).currencies`, not just `msg.currencies`) and gas covers payouts | Phase 1 run 3 |
| A lot's constructor must be infallible (a failed constructor leaves the code installed, holding the coins) | Phase 1 run 2 |
| Getters must not use DApp-context instructions (fail in local `tvm-cli run`, exit -36) | Phase 1 run 1 |
| Compile with `sold --tvm-version gosh`; `genaddr --save` for any externally deployed contract | Toolchain |
| A refused **non-bounceable** message strands its coins: read the bounce bit from `msg.data` (bit 5 of the first byte); if non-bounceable and carrying coins, accept and refund what arrived | Spike 6 (C1, C2, C8) |
| Flag-16 SHELL is converted to gas on arrival even when non-bounceable and refused; only a bounce returns it as SHELL | Spike 6 (C4, C5, C9, C10) |
| Refunds and owed payouts go `bounce: false`: a refusing wallet keeps the coins in its own account, so they never come back to be paid twice | Spike 6 (C8) |
| The Acki Nacki Wallet can only make plain transfers (no contract calls): lots accept pay-to-take via `receive()` | Bee SDK docs, `docs/WALLET_INTEGRATION.md` |

Open question for Phase 1: can validation run **before** `tvm.accept()` on a zero-value cross-DApp message?

## Phases

0. **Spikes** (this week): 5 questions, `spikes/`.
1. `AtomicSwap` FIXED mode, full invariant test matrix, Shellnet, CLI only.
2. `SwapFactory`, DROP mode, events (`LotCreated`, `Filled`, `Reclaimed`), watcher.
3. Signed quotes (haggle + private lots).
4. Independent review → mainnet with a hard `MAX_LOT_NOTIONAL` cap.

## Economics checks before launch

- Fee must cover sponsored gas per `take()` (measure in spike 3).
- Plan to seed both sides of the book at launch. Empty books killed dex.do's markets.
