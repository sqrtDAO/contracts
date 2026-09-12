# Dune Dashboard Setup — sqrtDAO Distribution Metrics (Sepolia)

## ✅ LIVE: Dashboard deployed (2026-09-08)

**Dashboard:** https://dune.com/ali77gh/sqrtdao-sepolia-distribution (id 219777)

The decoded contract tables already existed on Dune under schema
`sqrtdao_sepolia.<contract>_evt_<event>` (e.g. `sqrtdao_sepolia.distributionv1factory_evt_newdistributor`,
22 rows). DistributorV1 instances have **no** decoded tables (the ABI registration
has no addresses bound), so all DistributorV1 event queries (`Participated`,
`Claimed`, `DrainHookCall`, `HookFailure`) read raw `sepolia.logs` and discover
distributor addresses dynamically from the decoded `NewDistributor` table —
**new distributors are picked up automatically**, no maintenance needed.

Saved queries (source of truth: `queries/*.sql`):

| # | Query ID | Dune title |
|---|---|---|
| 1 | 8644849 | sqrtDAO - 1. KPI Overview (4 counter cards: distributions, unique participants, participation, claimed) |
| 2 | 8644850 | sqrtDAO - 2. Distributions Over Time |
| 3 | 8644848 | sqrtDAO - 3. Participation Over Time |
| 4 | 8644851 | sqrtDAO - 4. Per-Epoch Participation |
| 5 | 8644857 | sqrtDAO - 5. Distributor Leaderboard |
| 6 | 8644859 | sqrtDAO - 6. Claims Over Time |
| 7 | 8644856 | sqrtDAO - 7. Participation vs Claims |
| 8 | 8644858 | sqrtDAO - 8. Hook Health (empty until first `callDrainHook`) |

All 8 executed successfully against live data (22 distributions, 41
participations, 1800 tokens, 63.6% claim rate, 359 epochs).

To re-sync after editing a `queries/*.sql` file:

```sh
dune query update <query_id> --sql "$(cat queries/<file>.sql)"
```

## Below: original manual setup reference

Dashboard tracks your epoch-based distribution protocol: distributors created,
participation, claims, epoch funnels, and hook health.

## 1. Deployed addresses (Sepolia)

| Contract | Address | ABI file |
|---|---|---|
| FactoryV1 | `0x2821d8Fd1Ed684008d36f61074ACdc88299971e3` | — |
| Root token (ERC20, 18 decimals) | `0x40ce0bf2924a5f8870b9d3949972737b4494fabf` | — |
| FixedEmission | `0xfA0f8aBdd46BD55F7E915981f54A61B2CeD25dD8` | — |
| LinearEmission | `0xf3B24aC2eCf80c911E801AB68C3Ccf3799174574` | — |
| ExponentialEmission | `0xc131817C3B02048762AD2D8D04Cd608966ef8482` | — |
| TransferToHook | `0xfea9055f9A0E963D9e7d1a0AC2D7B19aC42793b4` | `dune/abis/TransferToHook.json` |
| BuyAndBurnHookV3 | `0x50C1EcD6B79731DE92Ee9BAcD1b87d6298b414aD` | `dune/abis/BuyAndBurnHookV3.json` |
| TokenV1Factory | `0x533ee7D342F2258b0d6E8f537DdE99f2aBe2701d` | `dune/abis/TokenV1Factory.json` |
| DistributionV1Factory | `0x533E7f8e7B4a741D0B0142b5aE97C5649E3f39f0` | `dune/abis/DistributionV1Factory.json` |
| DistributorV1 (many instances) | discovered via `NewDistributor` events | `dune/abis/DistributorV1.json` |

DistributorV1 instances are deployed dynamically by DistributionV1Factory —
you never hardcode them; queries discover them from `NewDistributor` events.

## 2. Upload ABIs to Dune

1. Log in to dune.com (Sepolia data is available on all plans; **uploading custom
   ABIs requires a paid plan** — if you're on the free plan use the raw-log
   fallback in `queries/_fallback_raw_logs.md`).
2. Go to **Data → My Creations → Contracts** (or "Create → Decode Contract"),
   click **Upload ABI / Add Contract**.
3. Register one entry per contract **with the exact name used in the table
   prefix**. Recommended project name: `sqrtdao` — tables then appear as
   `sepolia.sqrtdao_<contractname>_evt_<eventname>`.
4. For each: paste the contract address from section 1 and paste the contents of
   the matching ABI file (they are `{ "abi": [...] }` — paste the inner `abi`
   array if the form asks for the ABI array only).
5. Backfilling starts immediately; decoded tables appear within minutes.

Contracts to upload:

- `TokenV1Factory` @ `0x533ee7D342F2258b0d6E8f537DdE99f2aBe2701d`
- `DistributionV1Factory` @ `0x533E7f8e7B4a741D0B0142b5aE97C5649E3f39f0`
- `DistributorV1` — one upload, then **add every distributor address** as it is
  created. Fastest way: run the "Distributions created" query, copy the
  distributor addresses, and add them to the decoded contract.
- `TransferToHook` @ `0xfea9055f9A0E963D9e7d1a0AC2D7B19aC42793b4` (optional)
- `BuyAndBurnHookV3` @ `0x50C1EcD6B79731DE92Ee9BAcD1b87d6298b414aD` (optional)

## 3. Fix table names in queries

The queries in `queries/` use the assumed prefix `sepolia.sqrtdao_<contract>_evt_<event>`.

To check the exact decoded table names Dune generated:

- Open a new query, type the prefix and use autocomplete
  (e.g. `select * from sepolia.sqrtdao_distributionv1factory_evt_` + Ctrl+Space),
- or search "sqrtdao" in the **Data Explorer → My Decoded Contracts** panel,
- or run `show tables` scoped to your schema.

If Dune named them differently (e.g. `sepolia.sqrtdao_distributor_v1_evt_participated`),
do a find-and-replace of the table names in each query file before pasting.
Column names in decoded tables are the snake_cased event params, prefixed
`evt_` for block metadata (`evt_block_time`, `evt_block_number`, `evt_tx_hash`,
`evt_contract_address`) and `evt_` for indexed params (`evt_participant`,
`evt_claimant`).

## 4. Create the queries

For each file below: Dune → **Create → New Query** (set chain = Sepolia in the
editor), paste the SQL, run, save with a descriptive name.

| # | File | Panel type |
|---|---|---|
| 1 | `queries/1_kpi_overview.sql` | table (or split CTEs into single-value tiles) |
| 2 | `queries/2_distributions_over_time.sql` | bar chart |
| 3 | `queries/3_participation_over_time.sql` | bar chart |
| 4 | `queries/4_epoch_participation.sql` | bar chart (epoch on x-axis) |
| 5 | `queries/5_distributor_leaderboard.sql` | table, sort by participation |
| 6 | `queries/6_claims_over_time.sql` | bar chart |
| 7 | `queries/7_participation_vs_claims.sql` | line chart, 2 series |
| 8 | `queries/8_hook_health.sql` | table / bar chart |

Sanity-check each query runs before moving on. If a decoded table isn't found,
re-check section 3.

## 5. Assemble the dashboard

1. Dune → **Create → Dashboard**, name it e.g. `sqrtDAO — Sepolia Distribution`.
2. Add visualizations: on each saved query, click **"+ Add visualization"**,
   pick the chart type from the table above, then **Add to dashboard**.
3. Suggested grid layout:
   - Row 1: KPI tiles (distributions created, unique participants, total
     participation, total claimed, claim rate)
   - Row 2: Participation over time + Claims over time side by side
   - Row 3: Participation vs claims (full width line chart)
   - Row 4: Per-epoch participation (full width)
   - Row 5: Distributor leaderboard (table)
   - Row 6: Hook health (table)
4. Set the dashboard refresh / starring as desired; data refreshes automatically
   with Dune's scheduler.

## 6. Notes & caveats

- **Decimals**: all token amounts are divided by 1e18 (TokenV1 = standard OZ
  ERC20, 18 decimals). If any distribution uses a non-18-decimal participation
  token, adjust that panel.
- **uint256 params**: raw-log numeric decoding uses
  `varbinary_to_uint256(bytearray_substring(data, N, 32))`. Word offsets in
  `data` are 1-indexed bytes: word k starts at byte `(k-1)*32 + 1`.
- **Epoch math**: `Participated` emits a *range* (`fromEpoch, numEpochs,
  amountPerEpoch`), so per-epoch totals must be exploded — see query 4.
- **Participant vs recipient**: `Participated.participant` is indexed; the
  `recipient` (a non-indexed param) is who actually earns the reward. Unique
  participants in query 3 count participants (tx senders). To count
  recipients, swap `evt_participant` → `recipient`.
- **HookFailure** is emitted by the embedded SharesLib inside DistributorV1 —
  it is not in the DistributorV1 ABI, so query 8 reads raw logs with topic0
  (hash list in `queries/_fallback_raw_logs.md`).
- **New distributors**: every new DistributorV1 address must be added to the
  decoded `DistributorV1` entry in Dune, otherwise `Participated`/`Claimed`
  events from it are undecoded. Do this when you create a new distribution
  (or check the "Distributions created" query weekly).
- If a distributor's `DISTRIBUTION_TOKEN`/`PARTICIPATION_TOKEN` differ per
  instance, amounts from different distributors aren't directly comparable —
  the leaderboard shows them side by side for this reason.

## 7. Regenerating ABIs

ABIs were extracted from `out/<Contract>.sol/<Contract>.json` via forge build.
To regenerate after contract changes:

```sh
forge build
for c in TokenV1Factory DistributionV1Factory DistributorV1 TransferToHook BuyAndBurnHookV3; do
  jq '{abi: .abi}' "out/${c}.sol/${c}.json" > "dune/abis/${c}.json"
done
```
