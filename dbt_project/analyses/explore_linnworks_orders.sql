-- =============================================================================
-- analysis: explore_linnworks_orders.sql
-- purpose:  Unpack raw JSONB from bronze.linnworks_orders into readable
--           columns for exploratory review before writing the silver model.
--           Use this to identify data quality issues, null patterns,
--           data types, and transformation requirements.
--
-- layer:    bronze (read only, no data is created or modified)
-- schema:   bronze
-- source:   bronze.linnworks_orders (loaded by loaders/load_linnworks.py)
--
-- usage:    Run via dbt Power User preview or psql session.
--           Not materialized, analysis files never create database objects.
-- =============================================================================

select
    -- metadata columns added by the loader
    id                                              as bronze_row_id,
    ingest_timestamp                                as bronze_ingest_timestamp,
    source_file                                     as bronze_source_file,

    -- core order identifiers
    raw_data ->> 'pkOrderID'                        as order_id,
    (raw_data ->> 'NumOrderId')::int                as order_number,
    raw_data ->> 'ReferenceNum'                     as reference_number,
    raw_data ->> 'ExternalReference'                as external_reference,
    raw_data ->> 'SecondaryReference'               as secondary_reference,

    -- channel and source
    raw_data ->> 'Channel'                          as channel,
    raw_data ->> 'Source'                           as source,
    raw_data ->> 'SubSource'                        as sub_source,
    raw_data ->> 'SiteCode'                         as site_code,
    raw_data ->> 'FulfilmentLocationName'           as fulfilment_location,

    -- dates
    (raw_data ->> 'ReceivedDate')::timestamp        as received_at,
    (raw_data ->> 'ProcessedOn')::timestamp         as processed_at,
    (raw_data ->> 'DispatchedOn')::timestamp        as dispatched_at,

    -- customer
    raw_data ->> 'CustomerName'                     as customer_name,
    raw_data ->> 'CustomerEmail'                    as customer_email,

    -- address
    raw_data -> 'Address' ->> 'FullName'            as shipping_full_name,
    raw_data -> 'Address' ->> 'Address1'            as shipping_address_1,
    raw_data -> 'Address' ->> 'Address2'            as shipping_address_2,
    raw_data -> 'Address' ->> 'City'                as shipping_city,
    raw_data -> 'Address' ->> 'Region'              as shipping_region,
    raw_data -> 'Address' ->> 'PostCode'            as shipping_postcode,
    raw_data -> 'Address' ->> 'Country'             as shipping_country,

    -- raw data for reference
    raw_data

from bronze.linnworks_orders

order by ingest_timestamp desc, bronze_row_id desc