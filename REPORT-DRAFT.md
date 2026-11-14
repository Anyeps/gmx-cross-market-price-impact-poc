# DRAFT — GMX Immunefi Report: Cross-market price-impact split via ETH/USD [WETH-WETH]

> **STATUS: DRAFT ONLY — DO NOT SUBMIT.** Prepared 2026-11-14 for Fah's review.
> No Immunefi submission, no email, no contact with GMX or Immunefi has been made.
> The draft must be approved by Fah before anything is submitted. Payout address
> and payout currency are marked TBD in the checklist at the end.
>
> Finding ID (internal): G-P1-2(a), deepened 2026-11-14.
> Evidence base: `FINDINGS.md` and `DEEPENING.md` in
> `~/workspace/hunts/gmx/poc/g-p1-2/` (19/19 base tests, 36/36 deepening tests,
> all on fresh Arbitrum forks; independently re-run by the parent agent).

---

# Part 1 — 7-Question Gate (run before writing the report)

Gate source: Agentic Bug Hunter `skills/triage-validation/SKILL.md`
("One wrong answer = STOP. Kill it. Move on."). All seven questions answered
below, with evidence. Q8 is the skill's identity check for authenticated
(Web2) hunts; it is adapted at the end because this is a permissionless
smart-contract finding.

## Q1: Can an attacker use this RIGHT NOW, step by step? — PASS

The gate's template is written for HTTP requests; for a smart-contract
finding the equivalent is exact reproducible on-chain steps, which the PoC
provides (Foundry fork tests with exact function calls — see "Steps to
reproduce").

1. **Setup:** Own account only. No victim, no special access, no admin or
   keeper role, no oracle manipulation, no flash loan. Capital = collateral
   for the position at the trader's chosen leverage (impact per dollar is
   leverage-independent — proven in FINDINGS §(b): 2x/10x/50x pay the same
   impact per dollar; 200x/500x opens are cancelled by the min-collateral
   check). At $100k notional the saving is $14.19–$19.18; at $10.74M
   notional it is $6,872.31.
2. **Request (on-chain, exact):** via GMX V2 `ExchangeRouter.createOrder`,
   submit two `MarketIncrease` orders (isLong = false, same index token
   WETH): one on ETH/USD [WETH-USDC] `0x70d95587d40A2caf56bd97485aB3Eec10Bee6336`,
   one on ETH/USD [WETH-WETH] `0x450bb6774Dd8a756274E0ab4107953259d2ac541`,
   each for half the total size, USDC leg first. A keeper executes both
   (keepers execute any trader's orders; no keeper role is needed by the
   attacker). The exact calls are in the PoC: `_openShort(M_USDC, …)` then
   `_openShort(M_WETH, …)` in `test/GP12Deepen.t.sol` (`test_XMax_Split`,
   `test_A3_SplitAcrossMarkets` in `test/GP12PriceImpact.t.sol`).
3. **Result:** each position's stored `pendingImpactAmount` (× index price)
   is read back. The two legs together pay $3,843.44 of impact for
   $10,738,000 of short exposure, vs $10,715.75 for the same size as one
   order on [WETH-USDC] alone (DEEPENING.md, test 1).
4. **Impact:** the trader keeps $6,872.31 that the protocol's own pricing
   model says should have been collected as price impact; the
   [WETH-USDC] impact pool is underfunded by that amount.
5. **Cost:** minutes; no cost beyond the trade itself (position fees are
   identical split vs single — both legs pay the 0.06% not-improved factor
   on the same total notional; the only extra cost is one additional
   execution fee, ~$0.72 of keeper gas, the rest refunded — G-P1-4).

## Q2: Is the impact on the program's accepted impact list? — PASS (conditional)

- The finding is a pricing-logic error with direct, quantified financial
  impact: a trader systematically underpays a protocol fee (price impact),
  at the expense of the [WETH-USDC] impact pool. That is the standard
  Immunefi **High** class for smart contracts ("incorrect pricing / logic
  error with direct financial impact"), and it is not a theft/freeze/
  insolvency, so it is not Critical.
- It is **not** in the program's Known Issues (6 entries, program.md §6,
  read 2026-11-13 23:06 UTC): bonusRewards on transfer, liquidation-
  capping M-15, fee-topup expected behaviour (×2), swap-without-market-
  update M-04, ADL price wipe (fixed). None covers price-impact splitting
  or virtual inventory.
- **CONDITION (flagged, must be verified on the live page before
  submitting):** the text fetch of the Immunefi Scope page rendered the
  Critical impacts list in full but cut off the High/Medium "Impacts in
  Scope" list after "Temporary freezing of funds", and the "Out of scope"
  section rendered empty. The finding is not on any exclusion visible in
  the fetch, but the full High list and the Out of Scope list must be
  re-checked live before submission (see checklist). If the live High
  list excludes pricing-logic/fee-evasion impacts, this answer changes.

## Q3: Is the root cause in an in-scope asset? — PASS

- Root cause lives in GMX V2 Synthetics on Arbitrum: the price-impact
  calculation (`PositionPricingUtils.getPriceImpactUsd`,
  `PricingUtils.getPriceImpactUsdForSameSideRebalance` /
  `getPriceImpactUsdForCrossoverRebalance`, `MarketUtils.
  getAdjustedPositionImpactFactors`) and the DataStore market config
  (impact factors + shared `virtualTokenId`) for the two live ETH/USD
  markets. The gmx-synthetics repo is explicitly in scope (program.md §1:
  "all contracts in these two repos are in scope"), and both markets are
  live production Arbitrum markets. No third-party service is involved.

## Q4: Does it require privileged access that an attacker can't realistically get? — PASS

- No. Any trader with collateral can open positions on both markets. No
  admin role, no keeper role (keepers execute orders for anyone), no
  governance access, no physical access, no compromised victim account.
  The PoC runs under two fresh, unprivileged test accounts (userA/userB
  style; the effect is identity-independent).

## Q5: Is this already known or accepted behavior? — PASS (with the main triage risk disclosed)

- **Not in Known Issues** (see Q2) and not in the Guardian audit findings
  surfaced during this hunt (the ADL/PnL-cap item is the closest
  neighbour and it is a different issue, already fixed in release_2.2.1).
- **The ~zero factors on [WETH-WETH] ARE documented intended config —
  this is disclosed front and centre in the report, not hidden.** GMX's
  own docs ("Providing liquidity", docs.gmx.io, verified 2026-11-14)
  state: *"The major single-token markets (BTC/USD [WBTC.e-WBTC.e],
  ETH/USD [WETH-WETH]) have position impact factors set to zero — meaning
  no position price impact at all."* Verified live on-chain 2026-11-14
  via `DataStore.getUint`: positive factor 1e15 (= 1e-15 at 1e30
  precision), negative factor 2e15 (= 2e-15). See "Config-history recon"
  below.
- **What is NOT documented or acknowledged anywhere found is the
  cross-market interaction:** the zero-impact market shares a virtual
  inventory (`virtualTokenId 0x3c48…a051`) with the priced [WETH-USDC]
  market, so a trader can route half a trade through the zero-impact
  market and pay half the impact on the shared state. No doc, governance
  proposal, or Known Issue addresses a trader using the zero-impact market
  to discount impact on a priced market. GMX's docs instead state *"Each
  GM pool is risk-isolated"* — the shared virtual inventory is a
  cross-market pricing coupling that sits uneasily with that model (pool
  *funds* remain isolated; what leaks across markets is the impact
  *pricing state* and the impact revenue the priced market should have
  collected).
- The gate rule is "acknowledged/design decision → KILL IT". The zero
  factors are a design decision; **the interaction is not an acknowledged
  one**. The finding therefore passes Q5 — but this is the main triage
  risk, and the report puts the config question first so triage can judge
  it with full information. If GMX considers the interaction intended
  behaviour too, the report should be closed as such, not paid.

## Q6: Can you prove impact beyond "technically possible"? — PASS

- Yes — measured in dollars on a live Arbitrum fork, twice, on different
  blocks, and independently re-run. $100k split saves $19.18 (FINDINGS
  A1/A3, block 524054954) and $14.19 (DEEPENING test 1, block 524060716);
  max $10,738,000 split saves $6,872.31 (DEEPENING test 1). The saving is
  realised money the trader keeps (less impact deducted from the
  position), not a theoretical path. 19/19 base tests + 36/36 deepening
  tests pass; the deepening suite was independently re-run at block
  524062438 (36/36 pass).
- Honest scope note: the measured saving is on the **open** side, and the
  round trip is now measured too — see "Supporting evidence" (close-split
  verification, 6/6 tests, fork block 524063246, independently re-run at
  524063639): the close also saves, but the close eats 65–76% of the open
  saving, because the single's close earns a rebate the split forfeits on
  the WETH leg. Net round-trip saving is **$4.89 at $100k (49.9% of the
  single's net impact cost) and $53.19 at $1M (51.8%)**, all-in ≈ $3.59 /
  ≈ $51.89 after extra execution fees. The max-size ($10.738M) round trip
  was NOT tested — extrapolating the $1M pattern suggests roughly a quarter
  to a third of the $6,872 open saving would survive (~$1,700–$2,400),
  but that is an extrapolation, not a measurement, and the draft does not
  claim it. The open-side saving alone ($6,872.31 max per open) is the
  headline quantified impact.

## Q7: Is this a known-invalid bug class? — PASS

- Not on the skill's NEVER SUBMIT list (missing headers, SPF/DKIM,
  GraphQL introspection alone, banner disclosure, clickjacking,
  tabnabbing, CSV injection, CORS wildcard without proof, logout CSRF,
  self-XSS, open redirect alone, OAuth secret in mobile app, SSRF DNS
  callback only, etc.). A smart-contract pricing-logic error with a
  measured financial effect is a standard, payable Immunefi class.

## Q8 (identity check) — N/A BY DESIGN

- Q8 is the skill's check for authenticated (Web2) hunts (which session,
  cross-identity repro, stale credentials). This finding is permissionless:
  any trader identity — including a fresh account with no history — can
  execute it, and the PoC demonstrates it under multiple unprivileged
  test accounts. There is no identity-dependent behaviour to check.

## Gate result: PASS (7/7)

- Q2 and Q5 carry flagged conditions (re-verify the live High impacts
  list + Out of Scope list before submitting; the config question is
  disclosed front and centre in the report). No question fails. Proceeding
  to draft.

---

# Part 2 — Config-history recon (the intent question)

Question: were [WETH-WETH]'s position-impact factors ever non-zero, and was
the cross-market interaction considered when they were set to ~zero?

## What was tried

(a) **DataStore change events via `eth_getLogs`.** Checked the repo
(`contracts/data/DataStore.sol`): `setUint` / `setBytes32` / `setUintArray`
/ `setBytes32Array` emit **no events**. There are no config-change events
to query — this avenue is closed by design, not by effort.

(b) **Reading the factor keys at older blocks.** Computed the exact keys
from `Keys.positionImpactFactorKey` (`POSITION_IMPACT_FACTOR =
keccak256(abi.encode("POSITION_IMPACT_FACTOR"))`; key =
`keccak256(abi.encode(POSITION_IMPACT_FACTOR, market, isPositive))`):
- Positive key (M_WETH, isPositive=true):
  `0x6e0611944f4603e4b3eb24878be8b06c454f0d32cdbd115b6989ce8666412b9f`
- Negative key (M_WETH, isPositive=false):
  `0x6e3f4836d516e2b3c7d97f4eb14b647210743805f6625f18dc048184d42f3236`
- Current values verified live 2026-11-14 (DataStore
  `0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8`, Arbitrum):
  positive `0x38d7ea4c68000` = 1e15 (= 1e-15), negative
  `0x71afd498d0000` = 2e15 (= 2e-15). Keys and values check out.
- Historical reads: block **524,060,716** (2026-11-14) reads fine; block
  **524,000,000** (~62k blocks earlier, hours) already fails with
  `missing trie node ... state ... is not available`, and blocks
  523,000,000 / 522,000,000 / 521,600,000 / 510,000,000 / 500,000,000 all
  fail the same way (`historical state ... is not available`). The public
  RPC (`https://arb1.arbitrum.io/rpc`) retains only roughly the last few
  thousand blocks of state. **Historical factor values cannot be
  established from this RPC; an archive node would be required (not
  available to this hunt).**
- A full Timelock `CallExecuted` log scan over ~2 years was NOT attempted:
  with no DataStore events, it would require scanning every Timelock
  execution since the market's creation and decoding calldata for
  `setUint` calls carrying the two keys above — thousands of 10k-block
  `eth_getLogs` windows against a rate-limited public RPC. Recorded here
  as not feasible in this hunt, not as evidence of anything.

(c) **GMX public docs / governance history.** Verified by reading the
live pages 2026-11-14:
- GMX Docs, "Providing liquidity" (https://docs.gmx.io/docs/providing-liquidity/):
  *"The major single-token markets (BTC/USD [WBTC.e-WBTC.e], ETH/USD
  [WETH-WETH]) have position impact factors set to zero — meaning no
  position price impact at all. Smaller single-token markets may have
  non-zero position impact factors configured based on their liquidity
  depth."* **The zero factors are deliberate, documented config — today.**
- GMX governance proposal "Single Token Pools (GMX V2) - BTC and ETH"
  (https://gov.gmx.io/t/single-token-pools-gmx-v2-btc-and-eth/3348,
  Chaos Labs initial parameters): **Position Impact Exponent 2.00,
  Positive Factor 9.00E-11, Negative Factor 1.50E-10** for both gmBTC2
  and gmETH2. The live values (+1e-15 / −2e-15, exponent 1.0) are ~90,000×
  smaller than the launch recommendation — so the factors were reduced to
  ~zero at some point after the proposal (the proposal itself says
  parameters are "updated over time" by the Security Committee).
- **Nothing found** in either document (or in the Known Issues list)
  addressing the cross-market interaction: no statement that a zero-impact
  market sharing a virtual inventory with priced markets is intended, and
  no analysis of traders routing through it. The docs' isolation claim
  ("Each GM pool is risk-isolated") is about pool funds, not about the
  shared impact-pricing state.

## What is established vs not established

- **ESTABLISHED:** the ~zero factors on [WETH-WETH] are deliberate
  *today* (GMX's own docs). The finding is therefore about the
  interaction, not the factors in isolation.
- **ESTABLISHED:** the launch recommendation was non-zero (9e-11 /
  1.5e-10, exponent 2.00); the live factors are ~90,000× smaller, so a
  deliberate reduction to ~zero happened after the proposal.
- **NOT ESTABLISHED:** the exact date/transaction that set the factors to
  ~1e-15, and whether the Security Committee considered the
  shared-virtual-inventory interaction when doing so.
- **NOT ESTABLISHED (and not claimed):** that GMX considers the split a
  bug. That is exactly what the report asks triage to decide, with the
  config question front and centre.

---

# Part 3 — Report (Immunefi submission draft)

---

## Title

Cross-market price-impact split: routing through the zero-impact ETH/USD [WETH-WETH] market halves the price impact paid on ETH/USD [WETH-USDC]

## Severity: High — $25,000 (flat)

**One-line justification:** a deterministic pricing-logic error lets any trader evade up to 64% (~$6,872 per trade, on up to $10.74M per trade) of the price impact the protocol's own model charges, at the expense of the [WETH-USDC] impact pool — repeatable, with no special access and no oracle manipulation. It is not Critical because no user funds are stolen, frozen, or drained and no insolvency results; the loss is foregone impact revenue, not a loss of funds at rest.

## Summary

GMX V2 charges price impact on perpetual positions from the change in the
open-interest imbalance. Two ETH/USD markets share one virtual inventory
(`virtualTokenId 0x3c48977e4fc47fa4616e13af7ceb68b0d545dce7b1fb9ec7b85bb6e00870a051`):
ETH/USD [WETH-USDC] prices impact with factors +9.24e-8 / −1.11e-7
(exponent 1.56), while ETH/USD [WETH-WETH] prices it with factors ~1e-15
(exponent 1.0) — effectively zero. A trader who splits one short across
both markets pays the priced market's impact on only half the size and
~$0 on the other half, although both halves move the shared virtual
inventory by their full size. Measured on a live Arbitrum fork: a
$10,738,000 short split $5,369,000 / $5,369,000 pays **$3,843.44 of price
impact vs $10,715.75 for the same size as one order — a saving of
$6,872.31 (64.1%)**, net ~$6,871.59 after one extra execution fee. The
saving grows superlinearly with size and is bounded only by the
OI-reserve check on [WETH-WETH] (max leg ≈ $5,369,397).

## A question for triage, first (please read before judging severity)

We know the ~zero impact factors on ETH/USD [WETH-WETH] are **documented,
deliberate config** — GMX's own docs state the major single-token markets
"have position impact factors set to zero — meaning no position price
impact at all" (docs.gmx.io, "Providing liquidity"). We verified the live
values on-chain (DataStore: +1e-15 / −2e-15, exponent 1.0).

**This report is not claiming the zero factors themselves are a bug.**
The question we are asking is whether the **interaction** was intended:
the zero-impact market shares a virtual inventory with the priced
[WETH-USDC] market (and [WSTETH-USDE]), so the zero-impact market can be
used as a conduit to discount impact on the priced market by up to 64%.
We found no document, governance proposal, or Known Issue addressing that
interaction — and the launch recommendation for these markets (Chaos Labs,
GMX governance proposal "Single Token Pools (GMX V2) - BTC and ETH") was
for **non-zero** factors (+9.00E-11 / −1.50E-10, exponent 2.00), so the
factors were reduced to ~zero after launch.

If the GMX team considers this cross-market routing intended behaviour,
please close this as such — we would rather have a fast, honest "intended"
than a slow dispute. If it was not considered, the pricing asymmetry below
is real, deterministic, and repeatable, and the natural fix is to either
give [WETH-WETH] (and [WBTC-WBTC]) its own virtual inventory, or to
charge the shared-inventory impact at the priced market's factors
regardless of which market the trade is routed through.

## Impact

| Size (SHORT, ETH/USD) | Impact as one order ([WETH-USDC]) | Impact split 50/50 ([WETH-USDC] + [WETH-WETH]) | Saving | Saving % |
|---|---|---|---|---|
| $100,000 | −$27.67 | −$13.48 | $14.19 | 51.3% |
| $200,000 | −$58.09 | −$27.67 | $30.42 | 52.4% |
| $500,000 | −$164.18 | −$74.28 | $89.90 | 54.8% |
| $1,000,000 | −$383.71 | −$164.18 | $219.53 | 57.2% |
| $2,000,000 | −$954.34 | −$383.71 | $570.63 | 59.8% |
| $4,000,000 | −$2,512.47 | −$954.34 | $1,558.13 | 62.0% |
| $8,000,000 | −$6,908.29 | −$2,512.47 | $4,395.82 | 63.6% |
| **$10,738,000 (max)** | **−$10,715.75** | **−$3,843.44** | **$6,872.31** | **64.1%** |

(All rows: DEEPENING.md test 1, fork block 524060716, ETH $1,893.52.
Independent replication at $100k on a different block: single −$37.81 vs
split −$18.63, saving $19.18 / 50.7% — FINDINGS.md (a), block 524054954,
ETH $1,877.88. The absolute values differ between blocks because the live
OI imbalance differs; the ~50–64% saving reproduces.)

- **Round-trip net (measured, not extrapolated).** The open-side saving
  above is what the trader saves when opening. On the close, the single
  trade earns a rebate for removing a large short from a short-heavy
  market, and the split forfeits most of that rebate on the WETH leg
  (which earns ~$0 rebate at ~1e-15 factors). Measured round-trip net
  impact paid (true cash cost = −closeTotal, summed over legs — see the
  measurement note in CLOSE-SPLIT.md; the open pending is a deferred
  liability realised inside closeTotal, so open+close would double-count):

  | Size | Single net paid | Split net paid | Net saving | All-in net saving* |
  |---|---|---|---|---|
  | $100k | $9.80 | $4.92 | **$4.89 (49.9%)** | ≈ $3.59 |
  | $1M | $102.61 | $49.42 | **$53.19 (51.8%)** | ≈ $51.89 |

  \* After ~$1.30 extra execution fees (2 extra orders). The close eats
  64.6% of the open saving at $100k and 75.5% at $1M — about a quarter
  to a third of the open saving survives the close. Close order is
  irrelevant (WETH-first reverse close gives byte-identical totals).
  (CLOSE-SPLIT.md, 6/6 tests, fork block 524063246, ETH $1,895.08;
  independently re-run at block 524063639, 6/6 pass.) The max-size
  ($10.738M) round trip was **not** tested; do not extrapolate a
  round-trip number there.
- **Who loses:** the [WETH-USDC] impact pool. Price impact paid by a
  trader is collected into the market's impact pool (it funds future
  positive-impact rebates for traders who improve the balance). Every
  split trade deprives that pool of the evaded amount — up to $6,872 per
  max-size trade, repeatable without limit (each trade is independent;
  the discount does not degrade with repetition). Pool funds themselves
  are not removed; the loss is foregone impact revenue the protocol's
  own pricing model says should have been collected.
- **Who can do it:** any trader. No special access, no keeper role, no
  oracle manipulation, no flash loan, no victim. The only requirement is
  collateral for the position at the trader's chosen leverage (impact per
  dollar is leverage-independent — FINDINGS §(b)).
- **Why not Critical:** no user funds are stolen, frozen, or drained;
  no insolvency; the protocol does not lose funds at rest. The effect is
  a systematic pricing discount (fee/impact evasion) — the published High
  class for this shape. Funds directly at risk in the Critical sense
  (10% of funds affected) do not apply: the impact pool is underfunded
  by the evaded amount per trade, not emptied.
- **Bounds:** the maximum is set by the OI-reserve check on [WETH-WETH],
  not by max OI ($9.55M/side) or the factor caps (±40/50 bps). Max WETH
  leg ≈ **$5,369,397** (a $5.25M leg opens, a $5.5M leg fails with
  `InsufficientReserveForOpenInterest`). A $12M total split fails on the
  WETH leg; the single-trade curve continues past it ($12M single:
  −$12,661.53; $16M single: −$19,549.96 — both open on [WETH-USDC]).

## Vulnerability details

### The two markets and their live config

| | ETH/USD [WETH-USDC] | ETH/USD [WETH-WETH] |
|---|---|---|
| Market address | `0x70d95587d40A2caf56bd97485aB3Eec10Bee6336` | `0x450bb6774Dd8a756274E0ab4107953259d2ac541` |
| Index token | WETH | WETH |
| Long / short token | WETH / USDC | WETH / WETH |
| Position impact factor (+ / −) | +9.24e-8 / −1.11e-7 | **+1e-15 / −2e-15** |
| Position impact exponent | 1.56 | **1.0 (linear)** |
| Max impact factor (+ / −) | +40 bps / −50 bps | +40 bps / −50 bps |
| Impact pool | 445.45 WETH (~$837k) | 15.85 WETH |
| Max OI / side | $86.34M | $9.55M |
| `virtualTokenId` (shared) | `0x3c48977e4fc47fa4616e13af7ceb68b0d545dce7b1fb9ec7b85bb6e00870a051` | same |

(Live config at fork block 524060716, DEEPENING.md; factors re-verified
live 2026-11-14 via `DataStore.getUint` — see Part 2.)

### The mechanism

1. **Impact is a telescoping state function of the imbalance.**
   `PricingUtils.getPriceImpactUsdForSameSideRebalance` /
   `getPriceImpactUsdForCrossoverRebalance`: `impact = f(initialDiff) −
   f(nextDiff)`, with `f(D) = D^exponent × factor`. Splitting *within*
   one market therefore telescopes exactly — proven by the control
   (FINDINGS A4: $100k on [WETH-USDC] as 2×$50k sequential increases
   pays −$37.81, identical to the single order).
2. **The virtual inventory is shared across markets with the same index
   token, and it is the binding branch.** `PositionPricingUtils.
   getPriceImpactUsd` (:161) → `_getPriceImpactUsd` (:201) charges
   `min(real, virtual)` when the real impact is negative. All WETH-index
   markets share `virtualTokenId 0x3c48…a051`. A $100k trade moves the
   shared virtual inventory by **+53.25 WETH on either market**
   (FINDINGS §(a): A1 and A2 both measured +53.251538969476217863 WETH).
   The virtual branch is computed with the *market's own* factors — so
   the same +53.25 WETH movement costs −$37.81 through [WETH-USDC] and
   −$0.0002 through [WETH-WETH].
3. **The WETH leg is therefore free at every size.** Its impact is linear
   in leg size (factor 2e-15, exponent 1.0): a $50k leg pays
   −$0.0000000001; a $5,369,000 leg pays −$0.0107. The split total at size
   N is exactly the single-order impact at size N/2 plus ~$0, so the
   saving is `single(N) − single(N/2)` and grows superlinearly
   (exponent 1.56).
4. **Position fees cancel** — they do not explain the saving. Both the
   single order and both split legs worsen the balance, so all pay the
   live not-improved position-fee factor **0.06%** on the same total
   notional (0.06% × $10,738,000 = $6,442.80 either way; live factors
   verified in the DataStore, improved 0.04% / not-improved 0.06% —
   see the G-P1-4 correction in FINDINGS.md). The only extra cost of the
   split is one additional execution fee (0.001 ETH posted; the keeper
   keeps ~$0.72 of gas, the rest is refunded — G-P1-4, 9/9 tests pass).
   Net max saving ≈ **$6,871.59**.
5. **The virtual-inventory shift proves the causal channel** (DEEPENING
   test 2, supporting evidence only): opening a $2M [WETH-WETH] LONG
   first makes a later $100k [WETH-USDC] short $6.19 cheaper (−$21.48 vs
   control −$27.67); opening a $2M [WETH-WETH] SHORT first makes it
   $37.85 *more* expensive (−$65.52). All three values match the
   `min(real, virtual)` model to within $0.50. The shift is **not** a
   standalone exploit: the WETH leg's round-trip costs $2,001.30
   ($1,200 open fee + $800 close fee + ~$1.30 execution), so the net is
   −$1,995.11 at best. It is included here only as proof that the shared
   virtual inventory is the causal channel.
6. **The only bound is the OI-reserve check.** At the $5.5M WETH leg the
   rejection is `InsufficientReserveForOpenInterest(reservedUsd
   $6,287,561.73, maxReservedUsd $6,156,982.88)` — short OI after the leg
   must stay ≤ poolUsd × oiReserveFactor (1.0); pool is 6,502.13 WETH.
   Computed cap on the WETH leg: $6,156,982.88 − $787,561.73 =
   $5,369,421.15; practical max leg ≈ $5,369,397 (a $5,369,421 leg fails
   in the split sequence by a $24.53 margin — a small second-order effect
   on `maxReservedUsd` once the USDC half has opened, honestly noted in
   DEEPENING.md, cause not isolated, conclusion unchanged). Max OI
   ($9.55M/side) does not bind; the ±40/50 bps factor caps do not bind.
   Note: the deployed reserve check differs from the repo math (repo
   `validateOpenInterestReserve` would fail a $4M leg on these numbers;
   the deployed check passes it) — the threshold above is characterised
   empirically on the fork, not from repo code.

### Code paths (repo `gmx-synthetics` main @ a85ea34 — OLDER than deployed code; behaviour verified on the live fork)

- `PositionPricingUtils.getPriceImpactUsd` (:161) → `_getPriceImpactUsd`
  (:201): `balanceWasImproved = nextDiffUsd < initialDiffUsd`; same-side
  rebalance uses one factor, crossover uses both; virtual inventory is
  consulted only when the real impact is < 0, and `min(real, virtual)` is
  charged.
- `PricingUtils.getPriceImpactUsdForSameSideRebalance` /
  `getPriceImpactUsdForCrossoverRebalance`: the telescoping
  `f(D) = D^exponent × factor` formula.
- `MarketUtils.getAdjustedPositionImpactFactors`: clamps the positive
  factor down to the negative factor if larger; same for exponents.
- `MarketUtils.capPositiveImpactUsdByPositionImpactPool` (:912): positive
  impact at close is capped by the max positive factor AND by
  `poolUsd + maxLendableUsd` (maxLendable = 0 on Arbitrum ETH markets).
  **Negative impact is never pool-capped** — which is why the pool cannot
  be drained to discount a trade (FINDINGS §(c): the pool *grew* +$925
  after a drain attempt).
- `MarketUtils.validateReserve` (:1854) / `validateOpenInterestReserve`:
  the OI-reserve check that bounds the WETH leg (see §6 above).
- `DataStore` keys: `Keys.positionImpactFactorKey(market, isPositive)`,
  `Keys.positionImpactExponentFactorKey(market, isPositive)`,
  `Keys.maxPositionImpactFactorKey(market, isPositive)`.

## Steps to reproduce

All reproduction is on a **local Arbitrum fork** (Foundry). No mainnet
transactions were sent at any point. The harness sets oracle prices from
the **live Chainlink feed values read from the DataStore at the fork
block** (`Oracle.setPrimaryPrice`, pranking the ExchangeRouter which holds
CONTROLLER, + `Oracle.setTimestamps`), then calls handlers with **empty
`SetPricesParams`** so `setPrices()` is a no-op. No oracle forgery, no
fake prices: the bypass only skips the DON-signature delivery of prices
that are already live on-chain. (`withOraclePrices` clears prices at the
end of every handler call, so the harness re-sets them before every call;
`vm.txGasPrice(0.1 gwei)` before every create/execute/cancel.)

### 1. Clone the PoC and run the base tests

```bash
git clone <repo> gmx-poc   # PoC files are supplied with this report;
cd gmx-poc/poc/g-p1-2      # see "PoC files" in the checklist
export PATH="$PATH:/home/hatch/.foundry/bin"   # Foundry v1.9.0
forge test --match-contract GP12PriceImpactTest \
  --fork-url https://arb1.arbitrum.io/rpc \
  --fork-block-number 524057193
# Expected: 13 passed, 0 failed.
forge test --match-contract GP12ProbeTest \
  --fork-url https://arb1.arbitrum.io/rpc \
  --fork-block-number 524057193
# Expected: 6 passed, 0 failed.
```

Key assertions to inspect (test/GP12PriceImpact.t.sol):
- `test_A1_ShortUsdcOnly`: `_openShort(M_USDC, userA, 100_000e30, 10 ether)`
  returns pending impact −$37.81 (block 524054954; −$27.67 at block
  524060716 — the absolute value follows the live imbalance).
- `test_A2_ShortWethOnly`: `_openShort(M_WETH, userB, 100_000e30, 10 ether)`
  returns pending impact −$0.0002.
- `test_A3_SplitAcrossMarkets`: `_openShort(M_USDC, userC, 50_000e30, 5 ether)`
  + `_openShort(M_WETH, userC, 50_000e30, 5 ether)` returns −$18.63 total.
- `test_A4_SameMarketSplitControl`: $100k on [WETH-USDC] as 2×$50k
  sequential increases returns −$37.81 — identical to A1, proving the
  effect is cross-market, not splitting per se.
- `test_A5_SplitReverseOrder`: WETH leg first, then USDC leg — saving
  49.3% (order matters slightly; USDC-first is optimal).
- `_openShort` opens a MarketIncrease short via `ExchangeRouter.createOrder`
  and reads the position's stored `pendingImpactAmount` (index tokens) ×
  index price; the helper and the oracle setup are in the test file and
  `GmxForkHelpers`.

### 2. Run the deepening tests (max size + scaling)

```bash
forge test --match-contract GP12DeepenTest \
  --fork-url https://arb1.arbitrum.io/rpc \
  --fork-block-number 524060716
# Expected: 36 passed, 0 failed.
# (Independently re-run at block 524062438: 36 passed, 0 failed.)
```

Key assertions (test/GP12Deepen.t.sol):
- `test_XMax_Split`: $10,738,000 split ($5,369,000 + $5,369,000) pays
  −$3,843.44 vs `test_S…` single $10,738,000 at −$10,715.75.
- `test_X8M_Split`, `test_X4M_Split`, `test_X1M_Split`, `test_X100k_Split`:
  the scaling ladder in the Impact table above.
- `test_DiagSimulateXMax`: `simulateExecuteOrder` reproduces the
  `InsufficientReserveForOpenInterest` rejection at the $5.5M leg
  (reservedUsd $6,287,561.73 vs maxReservedUsd $6,156,982.88).
- `test_V0/V1/V2_Shift…`: the virtual-inventory shift measurements
  (−$27.67 / −$65.52 / −$21.48).

### 3. Verify the live config yourself (read-only, no fork needed)

```bash
# DataStore on Arbitrum:
#   0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8
# positionImpactFactorKey(M_WETH, isPositive) =
#   0x6e0611944f4603e4b3eb24878be8b06c454f0d32cdbd115b6989ce8666412b9f
# positionImpactFactorKey(M_WETH, isPositive=false) =
#   0x6e3f4836d516e2b3c7d97f4eb14b647210743805f6625f18dc048184d42f3236
cast call 0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8 \
  "getUint(bytes32)" \
  0x6e0611944f4603e4b3eb24878be8b06c454f0d32cdbd115b6989ce8666412b9f \
  --rpc-url https://arb1.arbitrum.io/rpc
# Expected: 0x38d7ea4c68000 = 1e15 (factor 1e-15 at 1e30 precision)
```

### 4. Manual reproduction (mainnet-equivalent steps, for triage — do NOT execute against mainnet)

1. Fund an account with WETH (for the [WETH-WETH] leg) and WETH or USDC
   (for the [WETH-USDC] leg).
2. Via `ExchangeRouter.createOrder`, open a MarketIncrease SHORT of size
   N/2 on ETH/USD [WETH-USDC], then a MarketIncrease SHORT of size N/2
   on ETH/USD [WETH-WETH] (USDC leg first). A keeper executes both.
3. Read each position's `pendingImpactAmount` (via `Reader.getPosition`)
   × the index price. Sum them and compare with the `pendingImpactAmount`
   of a single N-sized SHORT opened on [WETH-USDC] alone. The split sum
   is ~50–64% lower, as tabulated above.

## Supporting evidence

### Test results (all on fresh Arbitrum forks, live Chainlink prices)

| Suite | Tests | Block | Result |
|---|---|---|---|
| `GP12PriceImpactTest` | 13 (A1–A5, B1, B2, C1, C2, D1, D2 single, D2 five-piece, reserve-boundary probe) | 524054954 (ETH $1,877.88) | 13 passed |
| `GP12ProbeTest` | 6 (live impact config, WSTETH pools, GMX market, USDC pools, OI in tokens) | 524054954 | 6 passed |
| Re-run of both suites | 19 | 524057193 | 19 passed, 0 failed |
| `GP12DeepenTest` | 36 (probe, S/X ladder $100k–$16M + max, V0/V1/V2, swap tests, two simulate diagnostics) | 524060716 (ETH $1,893.52) | 36 passed |
| Independent re-run of deepening | 36 | 524062438 | 36 passed, 0 failed |

### Static analysis

Slither 0.11.6 on `PositionPricingUtils.sol`, `PricingUtils.sol`,
`SwapPricingUtils.sol`, `MarketUtils.sol`: **0 High findings**. Medium
findings are generic `divide-before-multiply` / `uninitialized-local` /
`unused-return` noise, none in the impact-calculation functions. (There
is no `PriceImpactUtils.sol` — the impact logic lives in
`PositionPricingUtils.sol` + `PricingUtils.sol`.)

### Negative results — what was tested and did NOT reproduce (boundaries of this report)

| Hypothesis | Result |
|---|---|
| Leverage reduces impact per dollar (FINDINGS §(b)) | NOT FOUND. 2x/10x/50x pay −$37.81/−$39.99/−$42.08 (drift = sequential-OI convexity); 200x/500x opens are cancelled (position size 0) by the min-collateral check. |
| Impact-pool drain (FINDINGS §(c)) | NOT FOUND. After a $1.55M LONG + $5M SHORT drain sequence the [WETH-USDC] impact pool **grew** +$925 (445.45 → 445.94 WETH); a fresh $100k SHORT afterwards pays the baseline −$37.81 exactly. Negative impact is never pool-capped. |
| Round trip / split close, same market (FINDINGS §(d)) | NOT FOUND as a loop. $100k SHORT round trip loses $10.26 net impact + $100 fees; a $500k close split five ways equals the single close exactly (−$53.11 both). |
| Virtual-inventory shift as a standalone exploit (DEEPENING test 2) | NOT FOUND as an exploit (mechanism real). Best case net −$1,995.11: the WETH leg's round-trip costs $2,001.30 vs a $6.19 impact saving. Included only as proof of the causal channel. |
| Same split on swaps (DEEPENING test 3) | NOT FOUND. USDC→WETH $100k pays −$160.01 impact; the WETH→WETH leg cannot even be created — order creation reverts `InvalidSwapMarket` (M_WETH has no virtualMarketId, swap factors 0/0). Saving: $0.00. |

### Round-trip (close leg) — VERIFIED 2026-11-14 (CLOSE-SPLIT.md)

The cross-market split close **was** verified after the first draft: 6/6
tests pass (fork block 524063246; independently re-run at 524063639, 6/6
pass). The close also saves, but it eats most of the open saving: net
round-trip saving is **$4.89 at $100k and $53.19 at $1M** (see the
round-trip table in "Impact" above). DEEPENING.md's unverified suggestion
that "the close can be split the same way" is therefore confirmed in
direction but corrected in size — the reportable round-trip saving at $1M
is $53.19, not $219.53 (the open-only figure). The max-size round trip
was not tested; no round-trip number is claimed there.

## References

- PoC evidence (supplied with this report):
  - `poc/g-p1-2/FINDINGS.md` — base finding, 19/19 tests
  - `poc/g-p1-2/DEEPENING.md` — max-size quantification, 36/36 tests
  - `poc/g-p1-2/test/GP12PriceImpact.t.sol`, `test/GP12Probe.t.sol`,
    `test/GP12Deepen.t.sol` — Foundry fork tests
  - `poc/g-p1-2/CLOSE-SPLIT.md` — cross-market split-close verification,
    6/6 tests (`test/GP12CloseSplit.t.sol`)
  - `poc/g-p1-4/FINDINGS.md` — execution-fee accounting (9/9 tests;
    establishes the ~$0.72 extra execution-fee cost and the live
    0.04%/0.06% position-fee factors)
- Program: GMX on Immunefi — https://immunefi.com/bug-bounty/gmx/information/
  (scope: https://immunefi.com/bug-bounty/gmx/scope/)
- GMX docs, "Providing liquidity" (single-token pools, zero impact
  factors): https://docs.gmx.io/docs/providing-liquidity/
- GMX governance proposal, "Single Token Pools (GMX V2) - BTC and ETH"
  (Chaos Labs initial parameters, non-zero factors):
  https://gov.gmx.io/t/single-token-pools-gmx-v2-btc-and-eth/3348
- Repo: https://github.com/gmx-io/gmx-synthetics (main @ a85ea34 at hunt
  time; note the deployed code is newer than this commit — all behaviour
  above was verified against the live deployment on the fork, not just
  the repo read)

## Submission checklist (complete before submitting)

- [ ] **Fah approves this draft** (required — no submission without it).
- [ ] Re-check the live Immunefi GMX page before submitting:
  - [ ] Full "Impacts in Scope" High/Medium list (the text fetch cut off
        after "Temporary freezing of funds") — confirm a pricing-logic /
        fee-evasion impact maps to High.
  - [ ] Full "Out of Scope" list + Prohibited Activities + Feasibility
        Limitations (rendered empty in the text fetch).
  - [ ] Known Issues list — confirm no new entry covers this since
        2026-11-13 23:06 UTC (6 entries then, none covering this).
  - [ ] Payout currency / payment rails (not stated in the text fetch).
  - [ ] Confirm first-report-wins still applies and the program is still open.
- [ ] Payout address: `0xC2B346278901012534De035421Be45f2Bd6348BF` —
  **TO BE CONFIRMED BY FAH at submission time** (do not submit with an
  unconfirmed address).
- [ ] Attach the PoC files listed under References (FINDINGS.md,
  DEEPENING.md, CLOSE-SPLIT.md, the four test files). Note in the
  submission that all tests run on a local Arbitrum fork; no mainnet
  transactions were sent.
- [x] "Round-trip (close leg)" section verified and updated with measured
  numbers (CLOSE-SPLIT.md, 6/6 tests, blocks 524063246 + 524063639).
  Optional follow-up only if Fah wants it before deciding: the max-size
  ($10.738M) round trip was not tested — one more fork test, same file
  shape, would pin that number.
- [ ] Submit promptly once Fah approves — **first report wins**; do not
  delay. Submit via "Submit a Bug" on
  https://immunefi.com/bug-bounty/gmx/information/ (Immunefi, triaged by
  Immunefi; KYC not required per the live page).
- [ ] No public disclosure before fix — keep the finding confidential
  until GMX/Immunefi authorise disclosure.
- [ ] After submission, track the report through triage to payout receipt
  (standing rule: payout to Fah's wallet; follow up if triage asks for
  clarification or a re-test).

---

*End of draft. Prepared 2026-11-14. DRAFT ONLY — DO NOT SUBMIT.*
