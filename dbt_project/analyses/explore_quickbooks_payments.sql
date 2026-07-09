-- =============================================================================
-- analysis: explore_quickbooks_payments.sql
-- purpose:  Unpack raw JSONB from bronze.quickbooks_payments into readable
--           columns for exploratory review before writing the silver model.
--
-- layer:    bronze (read only, no data is created or modified)
-- schema:   bronze
-- source:   bronze.quickbooks_payments (loaded by loaders/load_quickbooks.py)
--
-- usage:    Run via dbt Power User preview or psql session.
--           Not materialized, analysis files never create database objects.
-- =============================================================================

SELECT
    -- metadata columns added by the loader
    id                                              AS bronze_row_id,
    ingest_timestamp                                AS bronze_ingest_timestamp,
    source_file                                     AS bronze_source_file,

    -- core payment identifiers
    raw_data ->> 'Id'                               AS payment_id,
    raw_data ->> 'SyncToken'                        AS sync_token,

    -- dates
    (raw_data ->> 'TxnDate')::date                  AS transaction_date,
    (raw_data -> 'MetaData' ->> 'CreateTime')::timestamp     AS created_at,
    (raw_data -> 'MetaData' ->> 'LastUpdatedTime')::timestamp AS last_updated_at,

    -- customer
    raw_data -> 'CustomerRef' ->> 'value'           AS customer_id,
    raw_data -> 'CustomerRef' ->> 'name'            AS customer_name,

    -- amounts
    (raw_data ->> 'TotalAmt')::numeric              AS total_amount,
    (raw_data ->> 'UnappliedAmt')::numeric          AS unapplied_amount,

    -- payment method
    raw_data -> 'PaymentMethodRef' ->> 'value'      AS payment_method_id,
    raw_data -> 'PaymentMethodRef' ->> 'name'       AS payment_method,

    -- deposit account
    raw_data -> 'DepositToAccountRef' ->> 'value'   AS deposit_account_id,
    raw_data -> 'DepositToAccountRef' ->> 'name'    AS deposit_account_name,

    -- currency
    raw_data -> 'CurrencyRef' ->> 'value'           AS currency,

    -- process flag
    (raw_data ->> 'ProcessPayment')::boolean        AS process_payment,

    -- line details (first line example, can unnest for full array)
    (raw_data -> 'Line' -> 0 ->> 'Amount')::numeric AS line_amount,
    raw_data -> 'Line' -> 0 -> 'LinkedTxn' -> 0 ->> 'TxnId' AS linked_txn_id,
    raw_data -> 'Line' -> 0 -> 'LinkedTxn' -> 0 ->> 'TxnType' AS linked_txn_type,

    -- custom fields (example: first two entries)
    raw_data -> 'CustomField' -> 0 ->> 'Name'       AS custom_field_1_name,
    raw_data -> 'CustomField' -> 0 ->> 'StringValue' AS custom_field_1_value,
    raw_data -> 'CustomField' -> 1 ->> 'Name'       AS custom_field_2_name,
    raw_data -> 'CustomField' -> 1 ->> 'StringValue' AS custom_field_2_value,

    -- raw data for reference
    raw_data

FROM bronze.quickbooks_payments
ORDER BY ingest_timestamp DESC, bronze_row_id DESC;

RAW DATA:
{
  "Id": "5469",
  "Line": [
    {
      "Amount": 13283.76,
      "LinkedTxn": [
        {
          "TxnId": "1469",
          "TxnType": "Invoice"
        }
      ]
    }
  ],
  "TxnDate": "2025-06-29",
  "MetaData": {
    "CreateTime": "2025-06-29T00:00:00-07:00",
    "LastUpdatedTime": "2025-06-29T00:00:00-07:00"
  },
  "TotalAmt": 13283.76,
  "SyncToken": "0",
  "CustomField": [
    {
      "Name": "SwiftRoute Client ID",
      "Type": "StringType",
      "StringValue": "client_093",
      "DefinitionId": "1"
    },
    {
      "Name": "Days to Pay",
      "Type": "StringType",
      "StringValue": "27",
      "DefinitionId": "4"
    }
  ],
  "CustomerRef": {
    "name": "Morales, Medina and Williams",
    "value": "93"
  },
  "UnappliedAmt": 0,
  "ProcessPayment": false,
  "PaymentMethodRef": {
    "name": "ACH",
    "value": "1"
  },
  "DepositToAccountRef": {
    "name": "Checking — GTBank Business",
    "value": "35"
  }
}