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



RAW DATA:
{
  "id": "pcE~IM2cjlSbAcrwTYuYk0Fx",
  "notes": "Fragile — handle with care.",
  "state": 3,
  "worker": "drv_ic_015",
  "creator": "drv_ic_015",
  "shortId": "3c8e0609",
  "barcodes": {
    "capture": [],
    "require": [],
    "captureMaxCount": null
  },
  "executor": "yAM*fDkztrT3gUcz9mNDgNOL",
  "feedback": [],
  "identity": {
    "checksum": null,
    "failedScanCount": 0
  },
  "merchant": "yAM*fDkztrT3gUcz9mNDgNOL",
  "metadata": [
    {
      "name": "service_type",
      "type": "string",
      "value": "next_day",
      "visibility": [
        "api"
      ]
    },
    {
      "name": "client_id",
      "type": "string",
      "value": "client_023",
      "visibility": [
        "api"
      ]
    },
    {
      "name": "order_value",
      "type": "number",
      "value": 7.42,
      "visibility": [
        "api"
      ]
    },
    {
      "name": "zone_id",
      "type": "string",
      "value": "zone_abq_4",
      "visibility": [
        "api"
      ]
    },
    {
      "name": "vehicle_type",
      "type": "string",
      "value": "van",
      "visibility": [
        "api"
      ]
    }
  ],
  "quantity": 1,
  "container": {
    "type": "WORKER",
    "worker": "drv_ic_015"
  },
  "overrides": {},
  "appearance": {
    "triangleColor": null
  },
  "pickupTask": true,
  "recipients": [
    {
      "id": "gJmQgwaoQpEgCf",
      "name": "Sarah Mercer",
      "notes": "Call on arrival",
      "phone": "+19074269810",
      "hashedPhone": "c6poZJRiuKRTElXE",
      "timeCreated": 1749393055000,
      "organization": "yAM*fDkztrT3gUcz9mNDgNOL",
      "timeLastModified": 1751293855000,
      "skipSMSNotifications": false
    }
  ],
  "destination": {
    "id": "jJpV410TBPOw",
    "notes": "",
    "address": {
      "city": "Albuquerque",
      "name": "",
      "state": "New Mexico",
      "number": "3716",
      "street": "Proctor Trace",
      "country": "United States",
      "apartment": "Ste 208",
      "postalCode": "87590"
    },
    "location": [
      -106.635657,
      35.162761
    ],
    "metadata": [],
    "timeCreated": 1751293855000,
    "timeLastModified": 1751293855000
  },
  "serviceTime": 3,
  "timeCreated": 1751291035000,
  "trackingURL": "https://onfleet.com/track/3c8e0609",
  "dependencies": [
    "uYhsf0S~MU7kiTaLzAL*F2Q5"
  ],
  "organization": "yAM*fDkztrT3gUcz9mNDgNOL",
  "completeAfter": 1751293855000,
  "completeBefore": 1751384203707,
  "timeLastModified": 1751314915000,
  "completionDetails": {
    "time": 1751314915000,
    "result": "success",
    "actions": {},
    "distance": 7032.8,
    "successNotes": "",
    "failureReason": "",
    "photoUploadId": "ph_RpWbAr46pv",
    "photoUploadIds": [
      "ph_RpWbAr46pv"
    ],
    "successEvidence": "",
    "signatureUploadId": null,
    "firstPhotoUploadId": "ph_RpWbAr46pv",
    "unavailableAttachments": []
  },
  "estimatedArrivalTime": 1751314615000,
  "estimatedCompletionTime": 1751314915000
}