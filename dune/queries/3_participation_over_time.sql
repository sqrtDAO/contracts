-- Participation over time: daily participation volume, event count, unique participants
with distributors as (
    select distributor as distributor_address
    from sqrtdao_sepolia.distributionv1factory_evt_newdistributor
)
select
    date_trunc('day', l.block_time) as day,
    sum(varbinary_to_uint256(bytearray_substring(l.data, 97, 32))
        * varbinary_to_uint256(bytearray_substring(l.data, 65, 32))) / 1e18 as participation_tokens,
    count(*) as participation_events,
    count(distinct l.topic1) as unique_participants
from sepolia.logs l
where l.topic0 = 0x1a5fdcf1919a5328c22961f6ec47df566e2b19381c38fc3c63578c3b2a784905 -- Participated
  and l.contract_address in (select distributor_address from distributors)
group by 1
order by 1
