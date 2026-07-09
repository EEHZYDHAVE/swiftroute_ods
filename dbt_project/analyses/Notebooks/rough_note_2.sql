SELECT

item_title,

COUNT(*) AS records,

STRING_AGG(stock_item_id, ', ') AS stock_item_ids,

STRING_AGG(item_sku, ', ') AS skus

FROM (

SELECT

raw_data ->> 'ItemTitle' AS item_title,

raw_data ->> 'StockItemId' AS stock_item_id,

raw_data ->> 'ItemNumber' AS item_sku

FROM bronze.linnworks_inventory

)x

GROUP BY item_title

HAVING COUNT(*) > 1

ORDER BY records DESC;