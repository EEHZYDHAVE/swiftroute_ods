-- =============================================================================
-- analysis: explore_onfleet_workers.sql
-- purpose:  Unpack raw JSONB from bronze.onfleet_workers into readable
--           columns for exploratory review before writing the silver model.
--           Use this to identify data quality issues, null patterns,
--           data types, and transformation requirements.
--
-- layer:    bronze (read only — no data is created or modified)
-- schema:   bronze
-- source:   bronze.onfleet_workers (loaded by loaders/load_onfleet.py)
--
-- note:     onfleet_deliveries (task) records only ever carry a worker ID —
--           this is the ONLY table where a worker's name is resolvable.
--           Join onfleet_deliveries.worker_id to onfleet_workers.worker_id
--           to attach a driver name to a delivery.
--
-- usage:    Run via dbt Power User preview or psql session.
--           Not materialized — analysis files never create database objects.
-- =============================================================================

select
    -- metadata columns added by the loader
    id                                              as bronze_row_id,
    ingest_timestamp                                as bronze_ingest_timestamp,
    source_file                                     as bronze_source_file,

    -- core worker identifiers
    raw_data ->> 'id'                               as worker_id,
    raw_data ->> 'organization'                     as organization_id,

    -- identity
    raw_data ->> 'name'                             as worker_name,
    raw_data ->> 'displayName'                      as display_name,
    raw_data ->> 'phone'                            as phone,
    raw_data ->> 'imageUrl'                          as image_url,

    -- teams (Onfleet returns this as an array — kept raw for exploration)
    raw_data -> 'teams'                              as teams_raw,
    jsonb_array_length(raw_data -> 'teams')          as teams_count,

    -- vehicle (nested object)
    raw_data -> 'vehicle' ->> 'id'                   as vehicle_id,
    raw_data -> 'vehicle' ->> 'type'                 as vehicle_type,
    raw_data -> 'vehicle' ->> 'description'          as vehicle_description,
    raw_data -> 'vehicle' ->> 'licensePlate'         as vehicle_license_plate,
    raw_data -> 'vehicle' ->> 'color'                as vehicle_color,

    -- duty / task status
    (raw_data ->> 'onDuty')::boolean                 as on_duty,
    raw_data ->> 'activeTask'                        as active_task_id,

    -- timestamps (Onfleet uses epoch milliseconds)
    to_timestamp((raw_data ->> 'timeCreated')::bigint / 1000)       as created_at,
    to_timestamp((raw_data ->> 'timeLastModified')::bigint / 1000)  as last_modified_at,

    -- metadata (array of {name, type, value} — assumes single entry
    -- for employment_type, same pattern as task metadata; revisit this
    -- extraction if more metadata entries are added upstream)
    raw_data -> 'metadata' -> 0 ->> 'value'          as employment_type_raw,

    -- raw data for reference
    raw_data

from bronze.onfleet_workers

-- order by most recently ingested first
order by ingest_timestamp desc, bronze_row_id desc


RAW DATA:
{
  "id": "drv_ic_016",
  "name": "Sherri Fowler",
  "phone": "+14656482366",
  "teams": [
    "team_albuquerque"
  ],
  "onDuty": true,
  "vehicle": {
    "id": "akg8xdFtTC0x",
    "type": "CAR",
    "color": "silver",
    "description": "Cargo Van",
    "licensePlate": "ZU4169"
  },
  "imageUrl": null,
  "metadata": [
    {
      "name": "employment_type",
      "type": "string",
      "value": "IC",
      "visibility": [
        "api"
      ]
    }
  ],
  "_ods_note": "This is the only Onfleet file where a driver name is resolvable. Task objects only carry the worker ID.",
  "activeTask": null,
  "displayName": "Sherri",
  "timeCreated": 1704067200000,
  "organization": "yAM*fDkztrT3gUcz9mNDgNOL",
  "timeLastModified": 1751241600000
}