# GMX — Cross-market price-impact evasion (PoC)

**Finding:** splitting a position across two ETH/USD markets that share the
same virtual inventory lets a trader pay price impact on only part of the
trade. The `[WETH-WETH]` market has effectively-zero position-impact factors
(+1e-15 / −2e-15) while `[WETH-USDC]` charges normal factors
(+9.24e-8 / −1.11e-7), yet both markets move the same shared virtual
inventory. Charged impact is `min(real, virtual)` computed with each
market's own factors, so the WETH leg moves shared inventory almost for free.

**Measured (local Arbitrum fork, block 524062438):** a $10,738,000 short
split 50/50 pays **$3,843.44** impact vs **$10,715.75** as one order —
saving **$6,872.31 (64.1%)**, net ≈ $6,871.59 after one extra execution fee.
Saving grows superlinearly with size ($100k → ~$14–19, $1M → $219.53,
$8M → $4,395.82).

## Files

- `REPORT-DRAFT.md` — full report draft (severity High), incl. the
  config-history question: ~zero factors on `[WETH-WETH]` are documented
  intended config; the cross-market interaction via shared virtual inventory
  is undocumented anywhere.
- `FINDINGS.md` — original 19/19 fork tests (G-P1-2).
- `DEEPENING.md` — 36/36 deepening tests, incl. max-size quantification.
- `CLOSE-SPLIT.md` — 6/6 close-split tests (round-trip net saving only
  $4.89 at $100k / $53.19 at $1M — the close eats most of the open saving).
- `test/GP12PriceImpact.t.sol` — original PoC tests.
- `test/GP12Probe.t.sol` — config probes.
- `test/GP12Deepen.t.sol` — deepening tests (max size, swaps, leverage,
  pool drain, round trip).
- `test/GP12CloseSplit.t.sol` — close-split tests.

## Reproduce

```bash
forge test --fork-url https://arb1.arbitrum.io/rpc --fork-block-number 524062438
```

Note: the public RPC prunes old state — use a fresh fork block close to the
one above. The harness sets primary prices via `Oracle.setPrimaryPrice`
(pranked as ExchangeRouter) with `Oracle.setTimestamps(now, now)`, then
executes orders with empty `SetPricesParams`. See `FINDINGS.md` for the
full gotcha list.

## Status

Submitted to GMX via Immunefi (High). This repo is linked from the report
because Immunefi's submission form accepts only JPEG/PNG attachments.
