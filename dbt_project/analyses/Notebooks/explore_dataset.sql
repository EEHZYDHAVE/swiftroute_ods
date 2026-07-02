SELECT
    *
FROM 
    {{source('bronze', 'onfleet_deliveries')}}

ORDER BY ingest_timestamp ASC