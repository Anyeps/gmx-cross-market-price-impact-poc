# G-P1-2(a) CLOSE-SPLIT — does the split saving survive the close?

**Verdict: YES, the close also saves — but the close eats most of the open
saving. The net round-trip saving is roughly HALF the single's net impact
cost at both sizes tested, not the ~50–57% of the OPEN impact the split
appears to save.**

- Fork: Arbitrum, **block 524063246** (fresh, 2026-11-14 ~11:42 WIB),
  ETH **$1,895.08**. Same oracle price throughout each test, no price movement.
- Tests: `test/GP12CloseSplit.t.sol`, **6/6 pass** on that block (re-run
  reproduced the numbers exactly).
- No report drafted or submitted. Read-only mainnet, local fork only.

## Results (USD; negative = trader pays)

| Test | Open pending | Close totalImpact | Close rebate* | **Net impact paid** (−closeTotal) |
|---|---|---|---|---|
| $100k SINGLE [WETH-USDC] | −$26.82 | −$9.80 | +$17.01 | **$9.80** |
| $100k SPLIT ($50k USDC + $50k WETH) | −$13.04 (≈$0 WETH) | −$4.92 (≈$0 WETH) | +$8.13 (USDC leg) | **$4.92** |
| $1M SINGLE [WETH-USDC] | −$377.02 | −$102.61 | +$274.42 | **$102.61** |
| $1M SPLIT ($500k USDC + $500k WETH) | −$160.43 (≈$0 WETH) | −$49.42 (≈$0 WETH) | +$111.01 (USDC leg) | **$49.42** |

\* Close rebate = closeTotal − openPending: the price-impact earned back at
close when the short is removed (the position's stored pending is realised
inside closeTotal — see the measurement note below).

**Net round-trip saving (single minus split, true cash impact):**

| Size | Single net paid | Split net paid | **Saving** | Saving as % of single net |
|---|---|---|---|---|
| $100k | $9.80 | $4.92 | **$4.89** | 49.9% |
| $1M | $102.61 | $49.42 | **$53.19** | 51.8% |

**How much of the open saving does the close eat?**

| Size | Open saving (single − split open pending) | Close rebate lost (single − split rebate) | Net saving |
|---|---|---|---|
| $100k | $13.77 | $8.89 (64.6% eaten) | $4.89 |
| $1M | $216.59 | $163.40 (75.5% eaten) | $53.19 |

The mechanism is exactly the one the task hypothesised: the single's close
earns a large rebate (+$17.01 at $100k, +$274.42 at $1M) by removing a big
short from a short-heavy market, while the split's WETH leg earns ~$0 rebate
(open pending ≈ −$0.0000001 at $50k / −$0.000001 at $500k; close totalImpact
≈ −$0.00005 / −$0.0005 — the ~1e-15 factors charge ~nothing on either leg)
and its USDC leg earns only the half-size rebate. **The close does NOT eat
the whole saving: about a quarter to a third of the open saving survives
($4.89 of $13.77 at $100k; $53.19 of $216.59 at $1M).** The split still wins
the round trip by ~50% of the single's net impact cost.

**Close order is irrelevant.** Closing WETH-first then USDC (reverse-close
tests) gives byte-identical totals at both sizes (USDC leg close −$4.92 /
−$49.42 either way; WETH leg ≈ $0 either way). Each leg's close is priced
off its own market's state; the shared virtual inventory does not couple the
closes.

**Position fees cancel; execution fees don't.** Open fees (0.06% not-improved
on all legs, same total notional) and close fees (0.04% improved on all legs)
are identical single vs split. The split pays 2 extra execution fees
(4 orders vs 2), ~$0.65 keeper gas each (per DEEPENING test 2) ≈ **$1.30**,
so the all-in net saving is ≈ **$3.59 at $100k and ≈ $51.89 at $1M**.

## Measurement note — correction to the task's formula

The task asked for net = openPending + closeTotal. That **double-counts**:
`totalImpactUsd` at close is `proportionalPendingImpactUsd +
priceImpactUsd`, and for a full close proportionalPending == openPending
exactly (verified: closeTotal − openPending = the rebate, and the
impact-pool delta matches −closeTotal to the cent — see below). The open
pending is a deferred liability stored in the position, not cash paid at
open; the cash impact cost of the round trip is **−closeTotal** (summed over
legs), which is also what G-P1-2 D1 used ("net impact paid $10.26" =
−closeTotal, not open+close). Both numbers are logged per test in the test
file; the literal open+close sums are $36.62 (single) vs $17.96 (split) at
$100k and $479.63 vs $209.85 at $1M — the *difference* of those sums
($18.66 / $269.78) is the open saving plus the net saving counted together
and is **not** a cash amount. The verdict above uses the true cash net.

## Cross-checks (all pass)

- **Impact-pool delta = −closeTotal to the cent** on every leg at both sizes
  (asserted with $1 tolerance in every test; actual agreement is < $0.01 —
  e.g. $1M single pool delta +$102.608938 vs −closeTotal $102.608938). This
  validates the close-fee factor: every close here uses improved=true
  (0.04% — removing a SHORT from a short-heavy market improves the balance).
  A wrong factor would shift the measured closeTotal by exactly 0.02% × size
  ($20 at $100k, $200 at $1M) and break the pool match.
- **$100k single reproduces D1's shape** on a fresh block: open −$26.82
  (vs −$37.81 on block 524054954, −$27.67 in DEEPENING — OI drifts between
  blocks; the split/single comparison is always within one block, so the
  drift does not affect the saving), close −$9.80 (vs D1 −$10.26).
- **WETH leg is ~free on both legs of the round trip**, at both sizes:
  open pending −$0.0000001 ($50k) / −$0.000001 ($500k); close totalImpact
  −$0.00005 / −$0.0005.

## Method / oracle bypass (stated explicitly)

Same harness as G-P1-2 / G-P1-4 / DEEPENING. Prices are the **live Chainlink
feed values read from the DataStore at the fork block**, set via
`Oracle.setPrimaryPrice` (pranking the ExchangeRouter, which holds
CONTROLLER) + `Oracle.setTimestamps`, then each handler is called with
**EMPTY `SetPricesParams` so `setPrices()` is a no-op**. No oracle forgery,
no fake prices: the bypass only skips the DON-signature delivery of prices
that are already live on-chain. `withOraclePrices` clears all prices at the
END of every handler call, so prices are re-set before EVERY handler call.
`vm.txGasPrice(0.1 gwei)` before every create/execute; STD_FEE = 0.001 ETH.
Collateral is WETH (native ETH) at 10x on every leg. No mainnet testing;
local fork only. No report drafted or submitted (Fah decides).

## Implication for the report (for Fah's decision — no report drafted)

DEEPENING.md's unverified claim "the close can be split the same way" is
now **verified, with a correction to its size**: the close does split, but
it returns only ~25–35% of the open saving to the trader, because the
single's close earns a rebate the split forfeits on the WETH leg. The
reportable round-trip saving at $1M is **$53.19 of impact (~$51.89 all-in)**,
not $219.53 (the open-only figure). At the $10.738M max split the open
saving is $6,872.31; the round-trip net saving there was NOT tested here
(the $1M pattern suggests roughly a quarter to a third of it would survive
the close, i.e. order ~$1,700–$2,400, but that is an extrapolation, not a
measurement). If Fah wants the max-size round-trip number before deciding,
that is one more fork test, same file shape.

## Files

- `test/GP12CloseSplit.t.sol` — 6 tests (single / split / reverse-close at
  $100k and $1M), all passing on fork block **524063246**.
  Run: `forge test --match-contract GP12CloseSplitTest --fork-url
  https://arb1.arbitrum.io/rpc --fork-block-number 524063246`
  → **6 passed, 0 failed**.
- This file: `CLOSE-SPLIT.md`.
