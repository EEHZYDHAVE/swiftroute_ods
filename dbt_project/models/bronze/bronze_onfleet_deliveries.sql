-- bronze_onfleet_deliveries.sql
--
-- PASSTHROUGH VIEW — do not add transformations here.
-- Source table bronze.onfleet_deliveries is created and populated by
-- loaders/load_onfleet.py (reads from source_data/raw/onfleet/).
-- This view exists solely for dbt lineage visibility and IDE querying.

select * from {{ source('bronze', 'onfleet_deliveries') }}