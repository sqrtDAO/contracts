-- Distributions created over time (decoded NewDistributor events)
select
    evt_block_date as day,
    count(*) as distributions_created,
    sum(count(*)) over (order by evt_block_date) as cumulative_distributions
from sqrtdao_sepolia.distributionv1factory_evt_newdistributor
group by 1
order by 1
