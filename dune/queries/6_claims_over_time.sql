-- Claims over time: daily claimed volume, event count, unique claimants
with distributors as (
    select distributor as distributor_address
    from sqrtdao_sepolia.distributionv1factory_evt_newdistributor
)
select
    date_trunc('day', l.block_time) as day,
    sum(varbinary_to_uint256(bytearray_substring(l.data, 65, 32))) / 1e18 as claimed_tokens,
    count(*) as claim_events,
    count(distinct l.topic1) as unique_claimants
from sepolia.logs l
where l.topic0 = 0x9cdcf2f7714cca3508c7f0110b04a90a80a3a8dd0e35de99689db74d28c5383e -- Claimed
  and l.contract_address in (select distributor_address from distributors)
group by 1
order by 1
