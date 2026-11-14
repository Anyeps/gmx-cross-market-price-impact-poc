# GMX lead G-P1-2 — price-impact / swap-path manipulation

## Verdict: FOUND (test a) — cross-market split halves the impact paid

A $100k SHORT split $50k/$50k across two ETH/USD markets that share virtual
inventory pays **$18.63 of impact vs $37.81 for the same $100k as one order —
a saving of $19.18 (50.7%)**, repeatable and measured on a live Arbitrum fork.
The saving comes from routing half the size through ETH/USD [WETH-WETH],
whose impact factors are ~1e-15 (effectively zero) while it shares the same
virtual inventory as ETH/USD [WETH-USDC] — the WETH leg moves the shared
virtual inventory by its full size (+53.25 WETH for $100k) yet pays ~$0.0002
of impact.

Tests (b) leverage, (c) impact-pool drain, and (d) round-trip / split-close
are **NOT FOUND** (all negative, with exact numbers below). No report has
been submitted and none has been drafted.

**Deepening (2026-11-14, fork block 524060716, ETH $1,893.52): see `DEEPENING.md`.**
Max split $10,738,000 saves $6,872.31 (64.1%); binding constraint is the
OI-reserve check on [WETH-WETH] (`InsufficientReserveForOpenInterest`), not max OI.
Virtual-inventory shift is real but not self-sustaining (net −$1,995 at best).
Swaps are a clean NOT FOUND (`InvalidSwapMarket` on the cheap leg).

Fork: Arbitrum, block **524054954** (fresh, 2026-11-14 ~11:10 WIB), ETH
$1,877.88. An earlier run on block 524048515 (ETH $1,895.63) gave the same
conclusions with slightly different values (A1 −$36.07, A3 −$17.74, saving
$18.33 / 50.8%); the public RPC pruned block 524048515 mid-task, so all
numbers below are from 524054954 unless marked "old block".

## (a) Split across markets sharing virtual inventory — FOUND

All markets below are WETH-index; all values are the position's stored
`pendingImpactAmount` × price, in USD (negative = the trader pays).

| Test | Trade | Pending impact (USD) |
|---|---|---|
| A1 | $100k SHORT on [WETH-USDC] alone | **−$37.81** |
| A2 | $100k SHORT on [WETH-WETH] alone | **−$0.0002** |
| A3 | Split $50k [WETH-USDC] + $50k [WETH-WETH] | **−$18.63** (USDC half −$18.63, WETH half −$0.0001) |
| A4 | Control: $100k on [WETH-USDC] as 2×$50k sequential increases | **−$37.81** (identical to A1) |
| A5 | Split, reverse order ($50k WETH first, then $50k USDC) | **−$19.19** (WETH −$0.0001, USDC −$19.19) |

- **Saving: A1 −$37.81 vs A3 −$18.63 = $19.18 (50.7%).** A5 saves $18.62
  (49.3%); the ~3% order-dependence is the virtual inventory influencing the
  USDC half slightly.
- A4 proves the effect is cross-market, not splitting per se: splitting
  within one market telescopes exactly (same total, to the cent).
- **Shared virtual inventory (the mechanism):** all WETH-index markets share
  virtualTokenId `0x3c48977e4fc47fa4616e13af7ceb68b0d545dce7b1fb9ec7b85bb6e00870a051`.
  A $100k trade moves the shared virtual inventory by **+53.25 WETH on
  EITHER market** (A1 and A2 both measured +53.251538969476217863 WETH) — the
  WETH leg moves the shared state by its full size while paying ~nothing.
- **Why the WETH leg is free:** live impact factors on
  ETH/USD [WETH-WETH] `0x450bb6774Dd8a756274E0ab4107953259d2ac541` are
  **+1e-15 / −2e-15 with exponent 1.0 (linear)**, vs
  ETH/USD [WETH-USDC] `0x70d95587d40A2caf56bd97485aB3Eec10Bee6336` at
  **+9.24e-8 / −1.11e-7, exponent 1.56**. Same max caps (±40/50 bps), same
  virtual inventory — wildly different factors.
- **Scope / limits (not yet tested):** only $100k total was tested. The
  saving should grow superlinearly with size (impact exponent 1.56), but
  [WETH-WETH] has a small pool (15.85 WETH ~$30k) and max OI $9.55M/side, so
  the max routable size is untested — a follow-up should binary-search it.
  Swap-impact splitting was read in code but not empirically tested.
- **Is it config or a bug?** The ~zero factors on [WETH-WETH] may be a
  deliberate config choice (single-token market: longToken == shortToken ==
  WETH). But the virtual inventory is shared with [WETH-USDC] (and
  [WSTETH-USDE]), so the cheap market's trades move the shared state the
  expensive market prices off. If GMX intended [WETH-WETH] to be
  impact-free, it should not share the virtual inventory. The saving is
  material (50%) and repeatable; whether Immunefi treats it as a bug is a
  judgement call for Fah — no report drafted.

## (b) Leverage vs impact per dollar — NOT FOUND

| Test | Result |
|---|---|
| B1: $100k SHORT at 2x / 10x / 50x | −$37.81 / −$39.99 / −$42.08 |
| B2: $100k SHORT at true 200x ($500 collateral = 0.2663 ETH) and 500x ($200 = 0.1065 ETH) | execute ok=true, but **position size 0** — both orders CANCELLED |

- B1: the 2x value equals A1 exactly; the drift at higher leverage is fully
  explained by sequential-OI convexity (each $100k trade adds to the
  imbalance). Impact per dollar of notional is leverage-independent.
- B2: the min-collateral check binds. `willPositionCollateralBeSufficient`
  includes the full-close negative impact, so an over-leveraged open is
  cancelled by `_handleOrderError` (the outer `executeOrder` still returns
  ok=true — the test asserts on position size, not ok). The mitigation works.

## (c) Impact-pool drain — NOT FOUND

Market: [WETH-USDC], impact pool **445.45 WETH (~$837k)** before the test.
Sequence (all in one test, same fork):

| Step | Result (USD) |
|---|---|
| Baseline $100k SHORT pending (pristine fork) | −$37.81 |
| Baseline close totalImpact | −$10.26 |
| A: LONG $1.55M open, pending | −$81.09 |
| B: SHORT $5M open, pending | −$2,356.71 |
| A: LONG $1.55M close, totalImpact | −$1,578.91 (pool +0.8408 WETH = +$1,578.91 — exact match) |
| B: SHORT $5M close, totalImpact | +$653.76 (pool −0.3481 WETH = −$653.76 — exact match) |
| Pool after the sequence | 445.94 WETH (~$838k) — **net +$925, the pool GREW** |
| Fresh $100k SHORT pending (after the sequence) | **−$37.81 = baseline exactly** |

Why the drain fails (mechanism, verified in code and on the fork):

- **A's LONG overshot.** The TOKEN-denominated imbalance is only ~319 WETH
  short-heavy (old block: long OI 2,152.40 WETH vs short 2,471.65 WETH —
  note the USD OI diff is −$1.55M but the token path is what matters, since
  `USE_OPEN_INTEREST_IN_TOKENS_FOR_BALANCE = true`). A $1.55M LONG
  (817.6 WETH) crosses into long-heavy territory, and the crossover formula
  charges the net effect: `f_pos($605k) − f_neg($945k)` = −$136 (old block;
  −$81.09 on the fresh block). Overshooting a balance costs impact instead
  of earning it.
- **Negative impact is never pool-capped.** The fresh $100k SHORT pays
  exactly the baseline −$37.81 regardless of pool state. A drained pool
  cannot discount a large trade — the pool only caps POSITIVE impact
  (`capPositiveImpactUsdByPositionImpactPool`).
- **The pool is a ratchet.** Creating an imbalance costs more (negative
  factor 1.11e-7 > positive factor 9.24e-8, same exponent 1.56) than
  rebalancing it can ever extract. B paid $2,357 to create the imbalance
  and extracted only $654 at close; A paid $1,579. Net pool change +$925.
- **Small trades can't drain it either (C2):** 5× open+close of a $100k
  balancing LONG: pending +$25.41 each, close totalImpact −$10.12 each,
  **total earned −$50.58**; pool grew 445.4447 → 445.4716 WETH (+0.0269 WETH
  = +$50.58, exact match). Each round trip's close reverses its open, so
  the close's negative impact cancels the open's positive pending (negative
  factor > positive factor), minus fees. The pool grows; it does not shrink.
- The extractable positive impact is bounded by the imbalance's impact
  value f(D) — for [WETH-USDC]'s imbalance only ~$97 exists at the margin
  (old-block estimate) against an $837k pool. Draining it would need a
  ~$200M+ imbalance, which would cost more in negative impact than it
  could ever return.
- Note: the small-pool markets are not drain candidates either — GMX/USD
  [GMX-GMX] (pool ~1,958 GMX ~$14.9k) and [WETH-WETH] (pool 15.85 WETH)
  both have impact factors ~1e-14/1e-15, so they earn ~$0 positive impact
  by config and cannot be drained that way.

## (d) Controls / round trip / split close — NOT FOUND

| Test | Result (USD) |
|---|---|
| D1: $100k SHORT round trip (open + full close, same price) | open pending −$37.81; close totalImpact **−$10.26**; net impact paid **$10.26** |
| D2: $500k SHORT, open pending | −$209.98 |
| D2: single $500k close, totalImpact | −$53.11 |
| D2: five $100k closes, totalImpact | −$53.11 (pieces −$6.98, −$8.72, −$10.53, −$12.44, −$14.45) |

- D1: the round trip LOSES money — $100 of position fees (open 0.06% ×
  $100k = $60, close 0.04% × $100k = $40) + $10.26 net impact = $110.26
  total. No harvestable loop. (The old-block contaminated measurement of
  −$111.92 was open fee + close fee + net impact + a double-counted
  execution fee — see the harness note on the fee factor.)
- D2: five-piece close total equals the single-close total to ~1e-13.
  Neither the max-factor cap (scales with sizeDeltaUsd) nor the pool cap
  can be dodged by splitting a close. The per-piece impact grows as the
  close proceeds (−$6.98 → −$14.45) because the new positive impact
  decays as the OI normalises while the proportional pending stays
  constant (−$40.53/piece on the old block, verified against the
  PositionDecrease event).
- Impact is stored at open as `pendingImpactAmount` (index tokens) and
  realised at close as `totalImpactUsd = proportionalPendingImpactUsd +
  priceImpactUsd`, capped at −maxNegativeFactor (50 bps) × size, excess →
  `priceImpactDiffUsd`.

## Correction to G-P1-4 (flagged to the parent agent)

**G-P1-4's "POSITION_FEE_FACTOR = 0" is WRONG.** The live per-market
position fee factors are **improved 0.04% (`4e26`), not-improved 0.06%
(`6e26`)** — verified in the DataStore (`Keys.positionFeeFactorKey`) and
consistent with fork behaviour on every market tested. The zero value was
the base key, not the per-market key. This contaminates G-P1-4's D1
interpretation: the "$4.23 shortfall on a $3,850 close" is ~$3.85 position
fees + ~$0.38 net impact, NOT $4.23 of price impact. The G-P1-2 brief's
premise ("$3,850 close loses $4.23 to price impact") is therefore wrong in
attribution. The A/B tests here (which measure impact via
`pendingImpactAmount` directly) are unaffected; the D/C close measurements
read the fee factor live and add it back, and they reconcile with the
impact-pool deltas to the cent.

## Live config (fork block 524054954 unless marked old block)

- `USE_OPEN_INTEREST_IN_TOKENS_FOR_BALANCE = true` (the token-denominated
  OI path is live; the USD-path virtual inventory, $9.74M, is STALE and
  never updated while the flag is on).
- Virtual inventory (tokens path): **+420.01 WETH** (old block; net short
  ~$796k). All WETH-index markets share virtualTokenId
  `0x3c48977e4fc47fa4616e13af7ceb68b0d545dce7b1fb9ec7b85bb6e00870a051`.
- ETH/USD [WETH-USDC] `0x70d95587d40A2caf56bd97485aB3Eec10Bee6336`: impact
  factors +9.24e-8 / −1.11e-7, exponent 1.56, max ±40/50 bps, impact pool
  445.45 WETH, long pool 11,592.6 WETH (~$21.8M), short pool ~22.9M USDC,
  reserve factors 2.75, max OI $86.3M/side, OI long $4.86M / short $6.41M
  (USD). Token OI (old block): long 2,152.40 WETH / short 2,471.65 WETH,
  diff −319.25 WETH (~−$605k) vs USD diff −$1.55M — the token path is what
  the impact calc uses.
- ETH/USD [WETH-WETH] `0x450bb6774Dd8a756274E0ab4107953259d2ac541`: impact
  factors **+1e-15 / −2e-15, exponent 1.0 (linear)**, max ±40/50 bps,
  impact pool 15.85 WETH, pool 15.85 WETH, OI long $563k / short $795k,
  max OI $9.55M/side.
- ETH/USD [WSTETH-USDE] `0x0Cf1fb4d1FF67A3D8Ca92c9d6643F8F9be8e03E5`: impact
  factors +6.66e-8 / −8.0e-8, exponent 1.58, impact pool 5.83 WETH, long
  pool 4.82 wstETH (~$10.7k), short pool 71.5 USDE (~$71), OI long $3.26M /
  short $2.78M (USD). Token OI (fresh block): long 1,629.72 WETH / short
  1,381.69 WETH, diff +248.03 WETH (long-heavy).
- GMX/USD [GMX-GMX] `0xbD48149673724f9cAeE647bb4e9D9dDaF896Efeb`: GMX $7.59,
  impact factors ~+1e-14 / −1.5e-14, exponent 1.5576, max +50 bps / −500
  bps, impact pool ~1,958 GMX (~$14.9k), token pools ~68,627 GMX each
  side, max OI ~$981k/side, OI long $57.6k / short $68.6k.
- Position fee factors (all markets tested): improved 0.04%, not-improved
  0.06%.

## Code paths (repo `gmx-synthetics` main @ a85ea34 — OLDER than deployed code)

- Impact is a telescoping state function of the OI imbalance:
  `impact = f(initialDiff) − f(nextDiff)`, `f(D) = D^exponent × factor`
  (`PricingUtils.getPriceImpactUsdForSameSideRebalance` /
  `getPriceImpactUsdForCrossoverRebalance`). Splitting within one market
  cannot change the total (A4 confirms).
- `PositionPricingUtils.getPriceImpactUsd` (:161) → `_getPriceImpactUsd`
  (:201): `balanceWasImproved = nextDiffUsd < initialDiffUsd`; same-side
  rebalance uses one factor, crossover uses both (positive for the
  rebalanced part, negative for the overshoot). Virtual inventory is only
  consulted when the real impact is < 0, and `min(real, virtual)` is
  charged (more negative wins).
- `MarketUtils.getAdjustedPositionImpactFactors` clamps the positive factor
  down to the negative factor if larger; same for exponents. The
  round-trip open+close loses the (negative−positive) factor asymmetry —
  the pool's take.
- Positive impact at close is capped by the max positive factor (40 bps of
  size) AND by `poolUsd + maxLendableUsd` (`MarketUtils.
  capPositiveImpactUsdByPositionImpactPool`, :912); maxLendable = 0 on
  Arbitrum ETH markets, so the pool cap is exactly the pool amount.
  **Negative impact is NEVER pool-capped.** The impact pool is funded at
  close time when traders pay negative impact (via `payForCost`, converted
  collateral→index tokens at min/max prices) and debited when traders earn
  positive impact (can go "lent" via `lentPositionImpactPoolAmount`, but
  lending capacity is 0 here).
- Impact is stored at open as `pendingImpactAmount` (index tokens) and
  realised at close: `totalImpactUsd = proportionalPendingImpactUsd +
  priceImpactUsd`; negative total capped at −maxNegativeFactor (50 bps) ×
  size, excess → `priceImpactDiffUsd`.
- Min-collateral check (`PositionUtils.willPositionCollateralBeSufficient`,
  :347) includes the full-close negative impact (positive capped to 0,
  negative capped at `maxPositionImpactFactorForLiquidations`) — this is
  what cancels 200x/500x opens (B2).
- Swap impact (`SwapPricingUtils` / `SwapUtils`): same telescoping
  structure; positive swap impact capped by the swap impact pool
  (`applySwapImpactWithCap` / `getSwapImpactAmountWithCap`), remainder
  paid from the tokenIn swap pool; negative swap impact is stored in the
  pool. **Read only — not empirically tested.**
- Reserve check (`MarketUtils.validateReserve`, :1854): the deployed
  behaviour differs from the repo. M_WSTETH shows a size-dependent
  rejection whose threshold moves with live state (on block 524048515 a
  $100 LONG opened while $10k/$100k LONGs were cancelled; on block
  524054954 $1k/$5k LONGs and a $10k SHORT all opened), while the repo
  math (long reservedUsd ~$3.09M vs long pool ~$10.7k × 1.25) predicts ANY
  increase should fail. The exact binding check is NOT identified (the
  -vvvv trace RPC prunes the old block). Recorded as an observation only;
  it is why the drain test used M_USDC (deep pools) instead of M_WSTETH.

## Slither 0.11.6

Note: no `PriceImpactUtils.sol` exists in the repo — the impact logic
lives in `PositionPricingUtils.sol` + `PricingUtils.sol`. Slither was run
on `PositionPricingUtils.sol`, `PricingUtils.sol`, `SwapPricingUtils.sol`
and `MarketUtils.sol` (with `@openzeppelin/contracts@4.9.3` +
`prb-math@2.4.3` in `gmx-synthetics/node_modules/`).

- **0 High findings** on all four files.
- Medium findings are only Slither's generic checks — `divide-before-
  multiply` (in `Calc.boundMagnitude`, `Array.getUncompactedValue`,
  `MarketUtils.getNextFundingFactorPerSecond`), `uninitialized-local`
  (struct locals that are fully assigned before use), `unused-return` —
  none in the impact-calculation functions, none a real vulnerability.
  Counts: PositionPricingUtils 133 detectors (85 Medium / 18 Low / 30
  Informational), PricingUtils 3 (1 / 0 / 2), SwapPricingUtils 120
  (76 / 14 / 30), MarketUtils 116 (72 / 14 / 30).
- The `divide-before-multiply` hits are all outside the impact path
  (funding-factor calc, array utils, Calc helper) — no precision-loss
  issue in `getPriceImpactUsdForSameSideRebalance` /
  `getPriceImpactUsdForCrossoverRebalance`.

## Harness notes (read before re-running)

- **Oracle bypass (explicit):** the harness pranks the ExchangeRouter
  (which holds CONTROLLER) and calls `Oracle.setPrimaryPrice` +
  `Oracle.setTimestamps`, then calls handlers with EMPTY
  `SetPricesParams` so `setPrices()` is a no-op. This bypasses the
  production oracle-verification path (the same bypass G-P0-8/G-P1-4
  used). All prices are realistic live Chainlink feed values read from
  the DataStore at the fork block (WETH $1,877.88, USDE $0.9995; wstETH
  falls back to the WETH price when its feed is unreadable).
- `withOraclePrices` clears prices at the END of every handler call —
  re-set before EVERY handler call (`_setPricesAll` inside
  `_executeOrder`).
- `vm.txGasPrice(0.1 gwei)` before every create/execute/cancel; min
  execution fee at 0.1 gwei is 0.0004123455 ETH; `STD_FEE` = 0.001 ETH.
- **Non-WETH collateral approval fix:** `ExchangeRouter.sendTokens`
  routes through `Router.pluginTransfer`, so the ROUTER plugin
  (`0x7452c558d45f8afC8c83dAe62C3f8A5BE19c71f6`) — not the
  ExchangeRouter — is the one that does `transferFrom`. Approving only
  the ExchangeRouter fails with "ERC20: transfer amount exceeds
  allowance". `_createIncrease` now approves both.
- **Position fee factor is 0.04%/0.06% live** (see the G-P1-4 correction).
  Close impact is measured as `totalImpactUsd = payout −
  collateralBefore + closeFee` (WETH) or `(usdcGain − collBefore) ×
  USDC_PX + closeFee` (USDC), with balances snapshotted AFTER the
  decrease order is created (so the escrowed fee is excluded). For
  partial closes the unified per-piece formula is `totalImpact =
  closeFee − collateralDelta + payout` (partial closes return NO
  proportional collateral — it stays locked until full close).
  `balanceWasImproved = nextDiff < initialDiff` determines the 0.04% vs
  0.06% factor; getting it wrong shifts the measured impact by exactly
  the fee-factor difference (0.02% × size) — the impact-pool delta is
  the ground-truth cross-check (all C1/C2 pool deltas match the measured
  impacts to the cent).
- Deployed code ≠ repo main @ a85ea34 (2026-07-31): live handler
  addresses were verified empirically; the reserve-check behaviour
  differs from the repo (see the M_WSTETH observation above).
- Public RPC prunes old state — always use a FRESH fork block
  (`cast block-number --rpc-url https://arb1.arbitrum.io/rpc`). The
  tests currently pin block 524054954.
- `Position.getPositionKey` = `keccak256(abi.encode(...))`, not
  `abi.encodePacked`. Cancel returns collateral as WETH unless
  `shouldUnwrapNativeToken=true`; the fee always returns as native ETH.

## Files

- `~/workspace/hunts/gmx/poc/g-p1-2/test/GP12PriceImpact.t.sol` — 13 tests
  (A1–A5, B1, B2, C1, C2, D1, D2 single, D2 five-piece, reserve-boundary
  probe). Run: `forge test --match-contract GP12PriceImpactTest
  --fork-url https://arb1.arbitrum.io/rpc --fork-block-number 524054954`
  → **13 passed, 0 failed**.
- `~/workspace/hunts/gmx/poc/g-p1-2/test/GP12Probe.t.sol` — 6 probe tests
  (live impact config, WSTETH pools, GMX market, USDC pools, OI in tokens
  for M_USDC and M_WSTETH). → **6 passed, 0 failed**.
- This file: `~/workspace/hunts/gmx/poc/g-p1-2/FINDINGS.md`.

## Next steps (recommendation)

1. **Deepen finding (a) before moving on.** (i) Binary-search the max size
   routable through [WETH-WETH] and the saving at that size (reserve/pool
   caps untested). (ii) Test the virtual-inventory shift: open a large
   [WETH-WETH] position to move the shared virtual inventory, then measure
   a [WETH-USDC] trade's impact vs a control — if the virtual shift
   discounts the USDC trade, that is a stronger, cleaner exploit
   primitive than the split. (iii) Test the same split on swaps
   (SwapPricingUtils path, untested).
2. **Decide with Fah whether to report (a).** Do NOT draft or submit a
   report without his go-ahead. The finding is real and repeatable, but
   the ~zero factors on [WETH-WETH] may be intended config, so the
   reportability judgement (and any severity) is his.
3. Then move to **G-P1-5 (GM/GLV flows)**, the next P1 lead in
   `~/workspace/hunts/gmx/leads.md`.
