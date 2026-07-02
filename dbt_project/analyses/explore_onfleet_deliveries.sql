-- =============================================================================
-- analysis: explore_onfleet_deliveries.sql
-- purpose:  Unpack raw JSONB from bronze.onfleet_deliveries into readable
--           columns for exploratory review before writing the silver model.
--           Use this to identify data quality issues, null patterns,
--           data types, and transformation requirements.
--
-- layer:    bronze (read only, no data is created or modified)
-- schema:   bronze
-- source:   bronze.onfleet_deliveries (loaded by loaders/load_onfleet.py)
--
-- usage:    Run via dbt Power User preview or psql session.
--           Not materialized, analysis files never create database objects.
-- =============================================================================

select
    -- metadata columns added by the loader
    id                                              as bronze_row_id,
    ingest_timestamp                                as bronze_ingest_timestamp,
    source_file                                     as bronze_source_file,

    -- core delivery identifiers
    raw_data ->> 'id'                               as delivery_id,
    raw_data ->> 'shortId'                          as short_id,
    raw_data ->> 'trackingURL'                      as tracking_url,

    -- status and type
    (raw_data ->> 'state')::int                     as state_code,
    (raw_data ->> 'pickupTask')::boolean            as is_pickup_task,

    -- assignment
    raw_data ->> 'worker'                           as worker_id,
    raw_data ->> 'organization'                     as organization_id,
    raw_data ->> 'merchant'                         as merchant_id,
    raw_data ->> 'creator'                          as creator_id,

    -- timestamps (Onfleet uses epoch milliseconds)
    to_timestamp((raw_data ->> 'timeCreated')::bigint / 1000)       as created_at,
    to_timestamp((raw_data ->> 'timeLastModified')::bigint / 1000)  as last_modified_at,
    to_timestamp((raw_data ->> 'completeAfter')::bigint / 1000)     as complete_after,
    to_timestamp((raw_data ->> 'completeBefore')::bigint / 1000)    as complete_before,

    -- completion details
    raw_data -> 'completionDetails' ->> 'success'           as completion_success,
    raw_data -> 'completionDetails' ->> 'failureReason'     as failure_reason,
    raw_data -> 'completionDetails' ->> 'successNotes'      as success_notes,
    to_timestamp(
        (raw_data -> 'completionDetails' ->> 'time')::bigint / 1000
    )                                                        as completed_at,

    -- destination
    raw_data -> 'destination' ->> 'address'                 as destination_address,
    raw_data -> 'destination' -> 'location' ->> 0           as destination_lng,
    raw_data -> 'destination' -> 'location' ->> 1           as destination_lat,

    -- notes
    raw_data ->> 'notes'                            as notes,

    -- raw data for reference
    raw_data

from bronze.onfleet_deliveries

-- order by most recently ingested first
order by ingest_timestamp desc, bronze_row_id desc