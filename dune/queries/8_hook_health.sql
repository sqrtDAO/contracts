-- Hook health: epoch fund releases (DrainHookCall) and hook failures (HookFailure).
-- HookFailure is emitted by the embedded SharesLib inside DistributorV1, so it is
-- read from raw logs filtered by distributor addresses.
with distributors as (
    select distributor as distributor_address
    from sqrtdao_sepolia.distributionv1factory_evt_newdistributor
),
drains as (
    select
        date_trunc('day', l.block_time) as day,
        sum(varbinary_to_uint256(bytearray_substring(l.data, 1, 32))) / 1e18 as released_tokens,
        count(*) as drain_calls
    from sepolia.logs l
    where l.topic0 = 0x67181b96807e7dec275893412d1b28aa2ff6b52eff1771ef05ce5175dbca34e5 -- DrainHookCall
      and l.contract_address in (select distributor_address from distributors)
    group by 1
),
failures as (
    select
        date_trunc('day', l.block_time) as day,
        count(*) as hook_failures
    from sepolia.logs l
    where l.topic0 = 0x6371d9d0500173aeb1ef6b2c1d4dd2c7538cb445ce02a9f8f3b817b560a53e96 -- HookFailure
      and l.contract_address in (select distributor_address from distributors)
    group by 1
)
select
    d.day,
    d.released_tokens,
    d.drain_calls,
    coalesce(f.hook_failures, 0) as hook_failures
from drains d
left join failures f on f.day = d.day
order by d.day
