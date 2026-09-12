-- Participation vs claims by day (two series)
with distributors as (
    select distributor as distributor_address
    from sqrtdao_sepolia.distributionv1factory_evt_newdistributor
),
daily_participation as (
    select
        date_trunc('day', l.block_time) as day,
        sum(varbinary_to_uint256(bytearray_substring(l.data, 97, 32))
            * varbinary_to_uint256(bytearray_substring(l.data, 65, 32))) / 1e18 as participation_tokens
    from sepolia.logs l
    where l.topic0 = 0x1a5fdcf1919a5328c22961f6ec47df566e2b19381c38fc3c63578c3b2a784905 -- Participated
      and l.contract_address in (select distributor_address from distributors)
    group by 1
),
daily_claims as (
    select
        date_trunc('day', l.block_time) as day,
        sum(varbinary_to_uint256(bytearray_substring(l.data, 65, 32))) / 1e18 as claimed_tokens
    from sepolia.logs l
    where l.topic0 = 0x9cdcf2f7714cca3508c7f0110b04a90a80a3a8dd0e35de99689db74d28c5383e -- Claimed
      and l.contract_address in (select distributor_address from distributors)
    group by 1
)
select
    p.day,
    p.participation_tokens,
    coalesce(c.claimed_tokens, 0) as claimed_tokens
from daily_participation p
left join daily_claims c on c.day = p.day
order by p.day
