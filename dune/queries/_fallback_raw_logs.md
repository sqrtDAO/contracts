# Raw-log fallback (no ABI decoding needed)

Use these only if you can't upload ABIs to Dune (free plan) or decoded tables aren't ready.
All raw queries use `sepolia.logs` and filter on `topic0` = keccak256 of the event signature.

## Topic0 hashes (verified with `cast keccak`)

| Event (contract) | Signature | topic0 |
|---|---|---|
| `NewToken` (TokenV1Factory) | `NewToken(address)` | `0x0f53e2a811b6fd2d6cd965fd6c27b44fb924ca39f7a7f321115705c22366d623` |
| `NewDistributor` (DistributionV1Factory) | `NewDistributor(address)` | `0x26351e175ca0261735d5253c1386be151da58f10e7d60599db07cf0a412f2aa3` |
| `Participated` (DistributorV1) | `Participated(address,address,uint256,uint256,uint256)` | `0x1a5fdcf1919a5328c22961f6ec47df566e2b19381c38fc3c63578c3b2a784905` |
| `Claimed` (DistributorV1) | `Claimed(address,uint256,uint256,uint256)` | `0x9cdcf2f7714cca3508c7f0110b04a90a80a3a8dd0e35de99689db74d28c5383e` |
| `DrainHookCall` (DistributorV1) | `DrainHookCall(uint256,uint256)` | `0x67181b96807e7dec275893412d1b28aa2ff6b52eff1771ef05ce5175dbca34e5` |
| `HookFailure` (embedded lib, emitted from DistributorV1) | `HookFailure(bytes)` | `0x6371d9d0500173aeb1ef6b2c1d4dd2c7538cb445ce02a9f8f3b817b560a53e96` |
| `BoughtAndBurnedV3` (BuyAndBurnHookV3) | `BoughtAndBurnedV3(uint256,uint256)` | `0xa5e0c57a56fd3a2e05e47fd2fe0c27ffeb12b2961375e70a33239d0ab695af19` |
| `Transferred` (TransferToHook) | `Transferred(address,uint256)` | `0xe6d858f14d755446648a6e0c8ab8b5a0f58ccc7920d4c910b0454e4dcd869af0` |

## Indexed params in raw logs

- `Participated`: topic1 = `participant` (indexed). Non-indexed data (32-byte words, in order):
  `recipient, fromEpoch, numEpochs, amountPerEpoch`
- `Claimed`: topic1 = `claimant` (indexed). Data words: `fromEpoch, numEpochs, totalClaimed`
- `NewToken` / `NewDistributor`: topic1 = token / distributor address (indexed)

Decode helpers:

```sql
-- uint256 word -> number
bytearray_to_bigint(word, 0)

-- address topic -> address
bytearray_to_address(topic1)
```

## Example: participation over time from raw logs

```sql
select
    date_trunc('day', block_time) as day,
    sum(
        bytearray_to_bigint(bytearray_substring(data, 65, 32), 0)   -- amountPerEpoch
        * bytearray_to_bigint(bytearray_substring(data, 33, 32), 0) -- numEpochs
    ) / 1e18 as participation_tokens,
    count(*) as participation_txs,
    count(distinct bytearray_to_address(topic1)) as unique_participants
from sepolia.logs
where topic0 = 0x1a5fdcf1919a5328c22961f6ec47df566e2b19381c38fc3c63578c3b2a784905
  and contract_address in (
      -- all DistributorV1 instances; extend as they are created
      0x0000000000000000000000000000000000000000 -- replace with real distributor addresses
  )
group by 1
order by 1
```

Indexing math for `bytearray_substring(data, start_byte, length_bytes)` (1-indexed bytes):
- word 1 = bytes 1..32 → `bytearray_substring(data, 1, 32)`
- word 2 = bytes 33..64 → `bytearray_substring(data, 33, 32)`
- word 3 = bytes 65..96 → `bytearray_substring(data, 65, 32)`
- word 4 = bytes 97..128 → `bytearray_substring(data, 97, 32)`
