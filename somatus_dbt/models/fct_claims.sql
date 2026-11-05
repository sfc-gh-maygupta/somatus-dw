{{ config(
    materialized = 'incremental',
    unique_key   = 'claim_id',
    incremental_strategy = 'merge'
) }}

-- Clean claims for reporting. On each run, only claims loaded since the last run are processed.
select
    claim_id,
    member_id,
    client_id,
    try_to_date(service_date)       as service_date,
    cpt_code,
    paid_amount::number(12,2)       as paid_amount,
    claim_status,
    file_name,
    loaded_at
from {{ source('bronze', 'claims_raw') }}

{% if is_incremental() %}
  -- only new rows: anything loaded after the latest row already in this table
  where loaded_at > (select max(loaded_at) from {{ this }})
{% endif %}
