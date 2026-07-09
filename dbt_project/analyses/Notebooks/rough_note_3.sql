SELECT
    vin,
    COUNT(DISTINCT vehicle_id) AS vehicle_count,
    STRING_AGG(vehicle_id, ', ' ORDER BY vehicle_id) AS vehicle_ids
FROM (
    SELECT
    -- metadata columns added by the loader
    id                                                  AS bronze_row_id,
    ingest_timestamp                                    AS bronze_ingest_timestamp,
    source_file                                         AS bronze_source_file,

    -- core identifiers
    raw_data ->> 'id'                                   AS vehicle_id,
    raw_data ->> 'name'                                 AS vehicle_name,

    -- vehicle details
    raw_data ->> 'make'                                 AS make,
    raw_data ->> 'model'                                AS model,
    (raw_data ->> 'year')::int                          AS manufacture_year,
    raw_data ->> 'vin'                                  AS vin,
    raw_data ->> 'licensePlate'                         AS license_plate,

    -- classification
    raw_data ->> 'vehicleType'                          AS vehicle_type,
    raw_data ->> 'fuelType'                             AS fuel_type,
    raw_data ->> 'operationalStatus'                    AS operational_status,

    -- telemetry
    (raw_data ->> 'currentOdometerMeters')::bigint      AS current_odometer_meters,

    -- last known location
    (raw_data -> 'lastKnownLocation' ->> 'latitude')::numeric
                                                        AS last_latitude,
    (raw_data -> 'lastKnownLocation' ->> 'longitude')::numeric
                                                        AS last_longitude,

    -- tags (first two)
    raw_data -> 'tags' -> 0 ->> 'id'                    AS tag_1_id,
    raw_data -> 'tags' -> 0 ->> 'name'                  AS tag_1_name,
    raw_data -> 'tags' -> 1 ->> 'id'                    AS tag_2_id,
    raw_data -> 'tags' -> 1 ->> 'name'                  AS tag_2_name,

    -- full tags array
    raw_data -> 'tags'                                  AS tags,

    -- raw data
    raw_data

FROM bronze.samsara_vehicles
-- 
ORDER BY ingest_timestamp DESC, bronze_row_id DESC
) AS samsare_vehicle


WHERE vin IS NOT NULL

GROUP BY vin

HAVING COUNT(DISTINCT vehicle_id) > 1

ORDER BY vehicle_count DESC;