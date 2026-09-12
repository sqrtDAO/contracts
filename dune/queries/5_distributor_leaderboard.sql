-- Distributor leaderboard: participation vs claims per DistributorV1 instance
with distributors as (
    select
        distributor as distributor_address,
        evt_block_time as created_at
    from sqrtdao_sepolia.distributionv1factory_evt_newdistributor
),
participation as (
    select
        l.contract_address as distributor,
        sum(varbinary_to_uint256(bytearray_substring(l.data, 97, 32))
            * varbinary_to_uint256(bytearray_substring(l.data, 65, 32))) as total_participation,
        count(distinct l.topic1) as unique_participants,
        max(l.block_time) as last_participation
    from sepolia.logs l
    where l.topic0 = 0x1a5fdcf1919a5328c22961f6ec47df566e2b19381c38fc3c63578c3b2a784905 -- Participated
    group by 1
),
claims as (
    select
        l.contract_address as distributor,
        sum(varbinary_to_uint256(bytearray_substring(l.data, 65, 32))) as total_claimed,
        count(distinct l.topic1) as unique_claimants
    from sepolia.logs l
    where l.topic0 = 0x9cdcf2f7714cca3508c7f0110b04a90a80a3a8dd0e35de99689db74d28c5383e -- Claimed
    group by 1
)
select
    '0x' || lower(to_hex(d.distributor_address)) as distributor_address,
    date(d.created_at) as created_at,
    coalesce(p.total_participation, 0) / 1e18 as participation_tokens,
    coalesce(p.unique_participants, 0) as unique_participants,
    coalesce(c.total_claimed, 0) / 1e18 as claimed_tokens,
    coalesce(c.unique_claimants, 0) as unique_claimants,
    p.last_participation
from distributors d
left join participation p on p.distributor = d.distributor_address
left join claims c on c.distributor = d.distributor_address
order by participation_tokens desc
