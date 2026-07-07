-- SELECT
--     COUNT(line_amount - total_amount) AS diff
-- from (
--    SELECT
--     -- metadata columns added by the loader
--     id                                              AS bronze_row_id,
--     ingest_timestamp                                AS bronze_ingest_timestamp,
--     source_file                                     AS bronze_source_file,

--     -- core invoice identifiers
--     raw_data ->> 'Id'                               AS invoice_id,
--     raw_data ->> 'DocNumber'                        AS document_number,
--     raw_data ->> 'domain'                           AS domain,
--     raw_data ->> 'SyncToken'                        AS sync_token,

--     -- dates
--     (raw_data ->> 'TxnDate')::date                  AS transaction_date,
--     (raw_data ->> 'DueDate')::date                  AS due_date,
--     (raw_data -> 'MetaData' ->> 'CreateTime')::timestamp     AS created_at,
--     (raw_data -> 'MetaData' ->> 'LastUpdatedTime')::timestamp AS last_updated_at,

--     -- customer
--     raw_data -> 'CustomerRef' ->> 'value'           AS customer_id,
--     raw_data -> 'CustomerRef' ->> 'name'            AS customer_name,

--     -- amounts
--     (raw_data ->> 'TotalAmt')::numeric              AS total_amount,
--     (raw_data ->> 'Balance')::numeric               AS balance,

--     -- status
--     raw_data ->> 'EmailStatus'                      AS email_status,
--     raw_data ->> 'PrintStatus'                      AS print_status,

--     -- currency
--     raw_data -> 'CurrencyRef' ->> 'value'           AS currency,
--     raw_data -> 'CurrencyRef' ->> 'name'            AS currency_name,

--     -- billing email
--     raw_data -> 'BillEmail' ->> 'Address'           AS bill_email,

--     -- payment method
--     raw_data -> 'PaymentMethodRef' ->> 'value'      AS payment_method_id,
--     raw_data -> 'PaymentMethodRef' ->> 'name'       AS payment_method,

--     -- line item (first line example, can unnest for full array)
--     raw_data -> 'Line' -> 0 ->> 'Id'                AS line_id,
--     (raw_data -> 'Line' -> 0 ->> 'LineNum')::int    AS line_num,
--     (raw_data -> 'Line' -> 0 ->> 'Amount')::numeric AS line_amount,
--     raw_data -> 'Line' -> 0 ->> 'DetailType'        AS line_detail_type,
--     raw_data -> 'Line' -> 0 ->> 'Description'       AS line_description,
--     (raw_data -> 'Line' -> 0 -> 'SalesItemLineDetail' ->> 'Qty')::int AS line_qty,
--     (raw_data -> 'Line' -> 0 -> 'SalesItemLineDetail' ->> 'UnitPrice')::numeric AS line_unit_price,
--     (raw_data -> 'Line' -> 0 -> 'SalesItemLineDetail' ->> 'ServiceDate')::date AS line_service_date,
--     raw_data -> 'Line' -> 0 -> 'SalesItemLineDetail' -> 'ItemRef' ->> 'value' AS line_item_ref_id,
--     raw_data -> 'Line' -> 0 -> 'SalesItemLineDetail' -> 'ItemRef' ->> 'name' AS line_item_ref_name,

--     -- custom fields (example: first three entries)
--     raw_data -> 'CustomField' -> 0 ->> 'Name'       AS custom_field_1_name,
--     raw_data -> 'CustomField' -> 0 ->> 'StringValue' AS custom_field_1_value,
--     raw_data -> 'CustomField' -> 1 ->> 'Name'       AS custom_field_2_name,
--     raw_data -> 'CustomField' -> 1 ->> 'StringValue' AS custom_field_2_value,
--     raw_data -> 'CustomField' -> 2 ->> 'Name'       AS custom_field_3_name,
--     raw_data -> 'CustomField' -> 2 ->> 'StringValue' AS custom_field_3_value,

--     -- raw data for reference
--     raw_data

-- FROM bronze.quickbooks_invoices
-- ORDER BY ingest_timestamp DESC, bronze_row_id DESC
-- ) as quickbooks_invoices

-- WHERE (line_amount - total_amount) > 0.1;