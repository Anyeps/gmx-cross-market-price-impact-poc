# G-P1-2(a) DEEPENING — cross-market price-impact split

**Verdict: CONFIRMED and quantified.** A $10,738,000 SHORT split $5,369,000 / $5,369,000
across ETH/USD [WETH-USDC] and [WETH-WETH] pays **$3,843.44 of price impact vs
$10,715.75 for the same size as one order — a saving of $6,872.31 (64.1%)**.
The effect is deterministic, repeatable, and bounded only by the OI-reserve check
on [WETH-WETH]. The virtual-inventory shift (test 2) is real as a mechanism but
**not** a standalone exploit (net −$1,995 at best). Swaps (test 3) are a clean
**NOT FOUND** — the cheap leg cannot even be created there.

- Fork: Arbitrum, **block 524060716** (fresh, 2026-11-14), ETH **$1,893.51616399**.
- Tests: `test/GP12Deepen.t.sol`, **36/36 pass** on that block.
- G-P1-2 base finding: `FINDINGS.md` (19/19 pass on block 524057193).

## Method / oracle bypass (stated explicitly)

Same harness as G-P1-2/G-P1-4. Prices are the **live Chainlink feed values read
from the DataStore at the fork block**, set via `Oracle.setPrimaryPrice` (pranking
the ExchangeRouter, which holds CONTROLLER) + `Oracle.setTimestamps`, then each
handler is called with **EMPTY `SetPricesParams` so `setPrices()` is a no-op**.
No oracle forgery, no fake prices: the bypass only skips the DON-signature
delivery of prices that are already live on-chain. The `withOraclePrices`
modifier clears all prices at the END of every handler call, so prices are
re-set before EVERY handler call. `vm.txGasPrice(0.1 gwei)` before every
create/execute/cancel; min execution fee at 0.1 gwei is 0.0004123455 ETH;
this harness uses 0.001 ETH (`STD_FEE`). No mainnet testing; local fork only.
No report drafted or submitted (Fah decides).

## Live config at block 524060716 (`test_ProbeDeepenConfig`)

- **M_WETH** `0x450bb677` [WETH-WETH]: reserveFactor 1.05, oiReserveFactor 1.0,
  max OI **$9,553,000/side**, pool **6,502.13 WETH** (~$12.31M), OI long
  $545,188.38 / short $787,561.73, position impact factors **+1e-15 / −2e-15**,
  exponents 1.0 / 1.0, max impact factor +40 bps / −50 bps, impact pool 15.846 WETH,
  swap factors 0 / 0, swap fee 0 / 0, **no virtualMarketId**.
- **M_USDC** `0x70d95587` [WETH-USDC]: reserveFactor 2.75, oiReserveFactor 2.7,
  max OI $86,339,000/side, pool 11,626.63 WETH + $22,740,868.83 USDC, OI long
  $4,747,611.89 / short $5,965,700.43, swap impact factors +2e-10 / −3e-10,
  exponent 2.0, swap fee 0.05% / 0.07%, swap impact pool 1.359 WETH + $3,692.56 USDC,
  virtualMarketId `0xf5134a0a…`.
- Shared virtual inventory (positions, tokens path): **+257.36 WETH** (short-heavy).
  Virtual swap inventory (M_USDC vm): long 12,832.51 WETH, short $25,531.995 USDC.
- Both markets share virtualTokenId `0x3c48…a051`.
- Note: the test-file header comment still describes the G-P1-2 block (524054954);
  the values above are the deepening block's. The G-P1-2 header's "15.85 WETH pool"
  for M_WETH does not reproduce here (6,502.13 WETH); the reserve-check arithmetic
  in test 1 pins the pool independently (see below), so the fresh probe is authoritative.

## Test 1 — max size + scaling curve (SHORT, ETH/USD, USDC leg first, WETH leg second)

Each size is a fresh fork state (single and split never share state). The USDC half
always pays **exactly** the standalone half-size impact (identical to the last digit,
e.g. X8M USDC half −$2,512.47 = S4M single −$2,512.47); the WETH half pays ~$0.

| Total size | Single impact | Split impact | Saving (USD) | Saving (%) |
|---|---|---|---|---|
| $100,000 | −$27.67 | −$13.48 | $14.19 | 51.3% |
| $200,000 | −$58.09 | −$27.67 | $30.42 | 52.4% |
| $500,000 | −$164.18 | −$74.28 | $89.90 | 54.8% |
| $1,000,000 | −$383.71 | −$164.18 | $219.53 | 57.2% |
| $2,000,000 | −$954.34 | −$383.71 | $570.63 | 59.8% |
| $4,000,000 | −$2,512.47 | −$954.34 | $1,558.13 | 62.0% |
| $8,000,000 | −$6,908.29 | −$2,512.47 | $4,395.82 | 63.6% |
| **$10,738,000 (max)** | **−$10,715.75** | **−$3,843.44** | **$6,872.31** | **64.1%** |
| $12,000,000 | −$12,661.53 | WETH leg fails | — | — |
| $16,000,000 | −$19,549.96 | WETH leg fails | — | — |

The split total at size N is the single at size N/2 plus ~$0, so the saving is
`single(N) − single(N/2)` and grows superlinearly (impact exponent 1.56), as predicted.
The WETH half's impact is linear in leg size (factor 2e-15, exponent 1.0): $50k leg
→ −$0.0000000001; $5,369,000 leg → −$0.0107. Effectively zero at every size.

### Max routable size and the binding constraint

- Binary search on the WETH leg: **$5.25M opens, $5.5M fails** (X10.5M ok, X11M fails;
  X9M/X10M ok). A $6M WETH **LONG** also fails, so it is not a short-specific formula.
- The rejection is `InsufficientReserveForOpenInterest(reservedUsd, maxReservedUsd)`
  (selector `0xb98c6179`, confirmed via `simulateExecuteOrder`, which — unlike
  `executeOrder` — does not swallow the error into an order cancel). At the $5.5M leg:
  `reservedUsd = $6,287,561.73` (short OI after the leg: $787,561.73 + $5,500,000)
  vs `maxReservedUsd = $6,156,982.88` (poolUsd × oiReserveFactor 1.0, where poolUsd =
  (6,502.13 WETH raw / 2) × $1,893.52).
- Computed cap on the WETH leg: **$6,156,982.88 − $787,561.73 = $5,369,421.15**.
  A $5,369,421 leg fails in the split sequence by a **$24.53** margin
  (`test_DiagSimulateXMax`: reserved $6,156,982.73 vs max $6,156,958.20 — the max is
  $24.68 lower once the USDC half has opened; small second-order effect, cause not
  isolated, honestly noted). Practical max leg ≈ **$5,369,397**; the tested max split
  uses $5,369,000 legs (total **$10,738,000**, $421 of headroom) and opens cleanly.
- What does **NOT** bind: max OI ($9.55M/side — the $5.5M leg leaves OI at $6.29M);
  the max-factor cap (±40/50 bps — the WETH leg's impact is ~$0); the pool size
  directly (6,502 WETH is ample; it binds only *through* the OI-reserve check,
  poolUsd × 1.0). The deployed reserve check differs from the repo math (repo
  `validateOpenInterestReserve` would fail a $4M leg on these numbers; the deployed
  check passes it) — the threshold above is characterised empirically, not from repo code.
- The single-trade curve extends past the split max (S12M −$12,661.53, S16M
  −$19,549.96 both open on M_USDC, max OI $86.34M); only the WETH leg caps the split.

### Net vs gross (split)

Position fees **cancel**: the single $N short and both split legs all worsen the
balance, so all pay the live not-improved factor **0.06%** on the same total
notional N (0.06% × $10,738,000 = $6,442.80 either way). The only extra cost of
the split is one additional execution fee (0.001 ETH posted; keeper keeps ~$0.72
of gas, the rest is refunded). **Net max saving ≈ $6,872.31 − $0.72 ≈ $6,871.59.**
(The fee factors 0.04%/0.06% are live config, verified in G-P1-2/G-P1-4 and
reconciled exactly in test 2's round-trip costs below.)

### Order matters

All X tests open the USDC leg first, then the WETH leg — optimal. Opening the WETH
leg first pushes the shared virtual inventory further short-heavy and makes the
USDC leg slightly more expensive (G-P1-2 A5 reverse order: 49.3% saved vs 50.7%
USDC-first at $100k; the gap grows with size, cf. test 2).

## Test 2 — virtual-inventory shift (does the shared inventory discount a later trade?)

$100k SHORT on [WETH-USDC], control vs after a $2M [WETH-WETH] position.
Virtual inventory before: **+257.36 WETH** (short-heavy).

| | Virtual inventory after shift | USDC $100k short impact | vs control |
|---|---|---|---|
| V0 control (no shift) | +257.36 WETH | −$27.67 | — |
| V1 WETH $2M **SHORT** first | +1,313.60 WETH | −$65.52 | **+$37.85 worse** |
| V2 WETH $2M **LONG** first | −798.87 WETH | −$21.48 | **−$6.19 cheaper** |

WETH leg costs (both directions, measured from userB's ETH balance over the full
open → close round trip): open impact −$0.0040 (V1) / −$0.0035 (V2), close impact
−$0.0020 both, **round-trip cost $2,001.30** = $1,200 open fee (0.06%, worsens) +
$800 close fee (0.04%, improves) + ~$1.30 execution fees. The position closes
cleanly in both cases (virtual inventory after close: +310.17 WETH in both =
control +257.36 plus the USDC trade's own +52.8 WETH shift).

**Net: V1 −$37.85 − $2,001.30 = −$2,039.15. V2 +$6.19 − $2,001.30 = −$1,995.11.**
The primitive is **NOT self-sustaining**: the WETH leg's round-trip position fees
($2,000 on a $2M leg) dwarf any impact saving on the USDC trade ($6.19 at best).
It is not a standalone exploit. It is, however, the cleanest proof of the mechanism
(see below), and it shows the direction matters: a same-direction shift *hurts*,
an opposite-direction shift *helps* — by at most the gap between the virtual and
real branches.

### Mechanism, verified quantitatively

`PositionPricingUtils.getPriceImpactUsd` charges `min(real, virtual)` when the real
impact is negative (the virtual branch is skipped when real ≥ 0). V2 reveals the
**real** impact of the $100k USDC short: **−$21.48** (virtual is positive there, so
the real branch binds). The virtual branch, with negative factor 1.11e-7 and
exponent 1.56 (`f(D) = D^1.56 × 1.11e-7`, D = virtual imbalance in USD):

- V0: virtual $487,331 → $587,331 ⇒ f-diff ≈ **$27.7** (measured $27.67). Virtual binds.
- V1: virtual $2,487,338 → $2,587,338 ⇒ f-diff ≈ **$66** (measured $65.52). Virtual binds.
- V2: virtual −$1,512,765 → −$1,412,765 (long-heavy, improved, positive factor
  9.24e-8) ⇒ f-diff ≈ **+$41** (positive). Real binds at −$21.48.

All three measured values match the `min(real, virtual)` model to within $0.50.
Corollary: the real branch is computed on **token** OI (`USE_OPEN_INTEREST_IN_TOKENS`
is on), not USD OI — the implied token-OI imbalance is ~$337k, far smaller than
the stored USD-OI imbalance of $1,218,089 (long $4,747,612 vs short $5,965,700),
which is why the real impact (−$21.48) is smaller than a naive USD-OI calculation
would predict (~−$45).

## Test 3 — same split on swaps: NOT FOUND

- Baseline: USDC → WETH **$100k** via M_USDC: amountOut **$99,769.99**, impact
  **−$160.01** at the not-improved swap fee 0.07% (total cost $230.01 = $70 fee +
  $160.01 impact). Virtual swap inventory before: long 12,832.51 WETH, short
  $25,531.995 USDC.
- WETH → WETH via M_WETH: order creation **reverts `InvalidSwapMarket`**
  (selector `0xcb9bd134`) — a single-token market is not a valid swap market.
  M_WETH has **no virtualMarketId**, swap factors 0/0, swap fee 0/0.
- Multi-hop `[M_USDC, M_WETH, M_WSTETH]`: creation reverts `InvalidSwapMarket`.
  (2-hop `[M_USDC, M_WSTETH]` executes; its output measurement is not relied on.)
- Virtual-shift: after the (failed) WETH-swap attempt, USDC → WETH $100k gives
  **identical** amountOut $99,769.99 and impact −$160.01; virtual swap inventory
  unchanged. **Saving: $0.00.**
- Conclusion: the swap path cannot reproduce the effect at all — the cheap leg is
  structurally excluded (no virtual market id, zero swap factors, creation revert),
  not merely unprofitable.

## Report-readiness and severity (for Fah's decision — no report drafted)

- **The split (a) is report-ready as evidence.** It is a real, deterministic,
  repeatable pricing asymmetry on live config: the same $10.74M of short ETH
  exposure costs $3,843.44 split vs $10,715.75 single (64% less impact), available
  to any trader with no special access, no oracle manipulation, no reentrancy,
  no flash loan. The maximum extractable discount per trade is ~$6,872 (and the
  close can be split the same way, per G-P1-2 (d) — the saving applies on both legs
  of the round trip). The binding constraint (OI-reserve check) is a config-level
  cap, not a fix for the asymmetry: it limits size, it does not remove the discount.
- **Plausible severity: High ($25k flat).** This is a market-manipulation /
  pricing-logic issue, not a loss of user funds: the trader pays less impact, the
  pool/impact-pool absorbs the difference. It does not drain anything, so it is not
  Critical (10% of funds at risk, capped $5M). High is the published tier for this
  class (incorrect pricing / logic error with direct financial impact).
- **Honest flag — intended config is the main risk to the report.** The ~zero
  factors on [WETH-WETH] (+1e-15 / −2e-15, exponent 1.0) may be *deliberate*:
  a single-token market has no meaningful pool to protect (impact pool 15.8 WETH),
  and GMX may have set the curve to ~zero on purpose. If so, the split is "working
  as configured" and the report would likely be closed as intended behaviour or a
  config suggestion, not a paid bug. The counter-argument: factors of ~1e-15 are
  effectively a *disabled* curve while every other ETH market uses ~1e-7 with
  exponent 1.56, and the two markets share a virtual inventory that the curve is
  supposed to price — a disabled curve on one side of a shared inventory is exactly
  the shape of an oversight. **Recommendation: report as High, with the config
  question front and centre** (state the factors, the shared virtual inventory, and
  ask whether ~zero was intended). If Fah wants the intent question settled first,
  the next step is config history (were [WETH-WETH]'s factors ever non-zero?) —
  that is a recon task, not a fork test.
- **Test 2 (virtual shift) is supporting evidence only** — do not report it as a
  standalone finding (net negative at every size). Its value is proving the causal
  channel (shared virtual inventory) for the split.
- **Test 3 (swaps) is negative** — do not include it as a finding.

## Not re-tested (per instructions)

(b) leverage, (c) pool drain, (d) round-trip — all closed negative in G-P1-2.
The Known-Issue "price-impact calculation ignoring fees" shape and execution-fee
accounting (G-P1-4, closed negative) were not chased.

## Corrections / gotchas found during this deepening

- V2's close was first measured with the wrong fee factor (`improved=false`,
  0.06%) and read +$400.00. The close *improves* the balance (long-heavy diff
  $1.76M → $0.24M), so the correct factor is 0.04%; re-run with `improved=true`
  reads −$0.0020, and the round-trip cost $2,001.30 reconciles exactly
  ($1,200 + $800 + ~$1.30). Fixed in `test_V2_ShiftLongThenUsdc`.
- `simulateExecuteOrder` first reverted `PriceAlreadySet(WETH, …)` (0xded099de)
  because setUp had already set primary prices; clearing prices first (pranking
  the ExchangeRouter, which holds CONTROLLER) fixed it and exposed the real error.
  `clearAllPrices` without the prank reverts `Unauthorized` (0xa35b150b).
- The $24.68 second-order effect on `maxReservedUsd` after the USDC half opens
  (see test 1) is noted, not explained — it does not change any conclusion.
- No new Slither run: no contracts were touched (test file only); G-P1-2 already
  ran Slither over the pricing contracts with 0 High findings.

## Files

- `test/GP12Deepen.t.sol` — 36 tests, all passing on fork block **524060716**
  (probe, S/X ladder $100k–$16M + max, V0/V1/V2, swap baseline/wrong-pair/
  multi-hop/virtual-shift, two simulate diagnostics).
- Run logs (ephemeral, `/tmp`): `gp12deepen-run1.log` (23 tests),
  `gp12deepen-final.log` (36 tests).
