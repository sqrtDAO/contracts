-- KPI Overview: headline numbers for the whole protocol (one counter per column)
with distributors as (
    select distributor as distributor_address
    from sqrtdao_sepolia.distributionv1factory_evt_newdistributor
),
participation as (
    select
        count(distinct topic1) as unique_participants,
        sum(varbinary_to_uint256(bytearray_substring(data, 97, 32))
            * varbinary_to_uint256(bytearray_substring(data, 65, 32))) / 1e18 as total_participation_tokens
    from sepolia.logs l
    where l.topic0 = 0x1a5fdcf1919a5328c22961f6ec47df566e2b19381c38fc3c63578c3b2a784905 -- Participated
      and l.contract_address in (select distributor_address from distributors)
),
claims as (
    select
        sum(varbinary_to_uint256(bytearray_substring(data, 65, 32))) / 1e18 as total_claimed_tokens
    from sepolia.logs l
    where l.topic0 = 0x9cdcf2f7714cca3508c7f0110b04a90a80a3a8dd0e35de99689db74d28c5383e -- Claimed
      and l.contract_address in (select distributor_address from distributors)
)
select
    (select count(*) from distributors) as distributions_created,
    p.unique_participants,
    round(p.total_participation_tokens, 2) as total_participation_tokens,
    round(c.total_claimed_tokens, 2) as total_claimed_tokens
from participation p
cross join claims c
