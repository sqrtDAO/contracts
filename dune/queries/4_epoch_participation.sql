-- Per-epoch participation: rebuilds epoch-level totals by exploding each
-- Participated(fromEpoch, numEpochs, amountPerEpoch) range across its epochs.
with distributors as (
    select distributor as distributor_address
    from sqrtdao_sepolia.distributionv1factory_evt_newdistributor
),
exploded as (
    select
        l.topic1 as participant,
        cast(varbinary_to_uint256(bytearray_substring(l.data, 33, 32)) as bigint) + i as epoch,
        varbinary_to_uint256(bytearray_substring(l.data, 97, 32)) as amount_per_epoch
    from sepolia.logs l
    cross join unnest(sequence(0, cast(varbinary_to_uint256(bytearray_substring(l.data, 65, 32)) - 1 as integer))) as t(i)
    where l.topic0 = 0x1a5fdcf1919a5328c22961f6ec47df566e2b19381c38fc3c63578c3b2a784905 -- Participated
      and l.contract_address in (select distributor_address from distributors)
)
select
    epoch,
    sum(amount_per_epoch) / 1e18 as epoch_total_participation_tokens,
    count(distinct participant) as epoch_unique_participants
from exploded
group by 1
order by 1
