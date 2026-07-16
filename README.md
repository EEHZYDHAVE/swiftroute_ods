# 🚚 **SwiftRoute Logistics | Operational Data System**

> A production-grade, end-to-end data engineering project simulating an Operational Data System (ODS) for a regional last-mile delivery and fulfillment company. Built on the Medallion Architecture using Python, PostgreSQL, dbt, and Apache Airflow.

![Python](https://img.shields.io/badge/Python-3.13-blue?logo=python)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-336791?logo=postgresql)
![dbt](https://img.shields.io/badge/dbt-1.11-orange?logo=dbt)
![Airflow](https://img.shields.io/badge/Airflow-2.10.5-017CEE?logo=apacheairflow)
![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker)
![Status](https://img.shields.io/badge/Phase%201-Complete-brightgreen)

---

## 📋 **Table of Contents**

- [Project Overview](#-project-overview)
- [The Business: SwiftRoute Logistics](#-the-business-swiftroute-logistics)
- [The Problem Being Solved](#-the-problem-being-solved)
- [What Is an Operational Data System?](#-what-is-an-operational-data-system)
- [Architecture Overview](#-architecture-overview)
- [Data Flow](#-data-flow)
- [Data Sources](#-data-sources)
- [Data Warehouse Design](#-data-warehouse-design)
- [ETL and Load Strategy](#-etl-and-load-strategy)
- [Folder Structure](#-folder-structure)
- [Naming Conventions](#-naming-conventions)
- [Data Catalogue](#-data-catalogue)
- [Tech Stack](#-tech-stack)
- [How to Run](#-how-to-run)
- [Project Status](#-project-status)
- [Known Limitations and Design Decisions](#-known-limitations-and-design-decisions)
- [Next Phase](#-next-phase)

---

## 🎯 **Project Overview**

This project is a **simulated real-world engagement** built as a learning prototype for delivering Operational Data Systems to SMB founders and startup operators. The simulation mirrors the exact workflow a data engineering practitioner would follow with a real client:

1. Understand the business and its operating reality
2. Map the core operational entities that drive revenue, cost, risk, and control
3. Analyse source systems to understand where data is born and how it flows
4. Design the data warehouse schema (conceptual, logical, and physical ERD)
5. Build the extraction, transformation, and loading pipeline
6. Surface the data in a star schema ready for dashboards and operational reporting

The business chosen for the simulation is **SwiftRoute Logistics** — a regional last-mile delivery and fulfillment company operating across three cities in North America. All data is **synthetically generated** and mirrors the exact JSON structures returned by the real APIs of each source system, including documented data quality quirks that a practitioner would encounter in production.

---

## 🏢 **The Business: SwiftRoute Logistics**

SwiftRoute Logistics is a **mixed last-mile carrier and fulfillment operation** founded in Denver, Colorado in 2018. It serves 94 active business accounts ranging from e-commerce brands and retail chains to healthcare distributors and B2B corporate clients.

### What SwiftRoute Does

| Service | Description |
|---|---|
| Same-Day Delivery | Orders submitted before 11 AM delivered within 4 hours |
| Next-Day Delivery | Orders accepted until 6 PM delivered next business day |
| Scheduled Window Delivery | Client-specified delivery windows for B2B and healthcare |
| E-Commerce Fulfillment | Warehouse storage, pick-and-pack, and dispatch for 11 clients |
| Returns Management | Collection and restocking of customer returns |
| B2B Distribution Runs | Scheduled multi-stop routes for retail and FMCG clients |

### Operating Scale (June 2025)

- **~380 deliveries per day** across Denver, Salt Lake City, and Albuquerque
- **48 drivers** (32 FTE, 16 independent contractors)
- **35 vehicles** cargo vans, motorcycles, and box trucks
- **94 active business accounts** (9 Platinum, 28 Gold, 57 Standard)
- **11 fulfillment clients** with inventory stored in the Denver warehouse
- **18,000 sq ft** warehouse facility in Denver

### Source Systems

| System | Purpose |
|---|---|
| **Onfleet** | Transport Management System: orders, dispatch, delivery tracking |
| **Linnworks** | Warehouse Management System: inventory, fulfillment orders |
| **QuickBooks Online** | Finance: invoicing, payments, expenses |
| **Gusto** | Payroll: FTE employee compensation |
| **Samsara** | Fleet Management: GPS tracking, fuel, driver safety |
| **Salesforce** | CRM: client accounts, contracts, rate cards |

---

## ❗**The Problem Being Solved**

SwiftRoute operates across six software platforms. **None of them are integrated with each other.** Each system knows one slice of the business and nothing else.

This fragmentation means the leadership team cannot answer the questions that matter most:

| Question | Why It Cannot Be Answered Today |
|---|---|
| What is our on-time delivery rate by zone and driver? | Pickup timestamps are inconsistently captured in Onfleet and have never been joined to SLA windows |
| What does it actually cost us to make a delivery? | Driver pay (Gusto), fuel (Samsara), and delivery volume (Onfleet) have never been connected |
| Which clients are profitable after accounting for operational burden? | Revenue lives in QuickBooks; cost lives in Gusto and Samsara; no system connects them |
| What is our actual monthly revenue? | Billing is calculated manually from Onfleet exports — a 3 to 5 day process every month-end |
| Which drivers are underperforming? | No single view combining completion rate, SLA achievement, and failure reasons per driver |

The root cause is not that the data does not exist. **The data exists across six systems but has never been assembled into a single analytical layer.** The ODS closes that gap.

---

## 💡 **What Is an Operational Data System?**

An **Operational Data System (ODS)** is a lightweight data infrastructure designed specifically for the scale and operational reality of SMBs and startups. It:

- Captures daily business activity from source systems
- Moves that data through automated transformation pipelines
- Surfaces it in dashboards and reports that founders and operators can use to make decisions

> *"An ODS is the analytical layer built around the core operational entities of the business that directly produce revenue, cost, risk, and control."*

Unlike a traditional BI project that starts from reporting requirements, an ODS starts from the operational entities of the business, the things that are actually happening day to day, and builds upward from there.

---

## 🏗️ **Architecture Overview**

This project implements the **Medallion Architecture** on PostgreSQL, with dbt handling all transformation logic and Apache Airflow orchestrating the full pipeline.

![Data Architecture](images/Data%20Architecture.png)

### The Three Layers

| Layer | What It Contains | How It Is Built |
|---|---|---|
| **Bronze** | Raw records exactly as they arrived from source. No transformation. Stored as JSONB with loader metadata. | Python loader scripts writing to PostgreSQL |
| **Silver** | Cleaned, standardised, typed records. One table per source entity. Surrogate keys generated. Data quality fixes applied. | dbt incremental models (upsert by natural key) |
| **Gold Operations** | Star schema fact and dimension tables built around the core operational entities of SwiftRoute. | dbt table and incremental models |

### The Five Root Questions the Gold Layer Answers

1. **Are we keeping our promises to clients?** On-time rate, SLA achievement, failure analysis
2. **Are we capturing all the revenue our operations generate?** Billing accuracy, revenue by client
3. **What does it actually cost us to serve each part of the business?** Cost per delivery, margin by zone
4. **How effectively are we deploying our operational capacity?** Driver utilisation, vehicle efficiency
5. **Where is operational risk concentrated?** AR ageing, COD leakage, driver compliance

---

## 🔄 **Data Flow**

![Data Flow Diagram](images/Data%20Flow%20Diagram.png)

The pipeline runs in five sequential stages:

**Stage 1: Simulate**
The incremental simulator (`simulators/run_simulation.py`) generates new JSON files for all six source systems, advancing the dataset forward by 7 days per run. On the first run, this produces the full historical dataset (January 2025 to June 2025). On subsequent runs, it produces only new incremental data.

**Stage 2: Load (Bronze)**
Python loader scripts (`loaders/load_*.py`) read the JSON files, check `bronze.pipeline_state` to skip already-processed files, and insert raw records into the bronze tables as JSONB. Each record gets an `ingest_timestamp` and `source_file` column added by the loader.

**Stage 3: Transform (Silver)**
dbt runs 18 incremental silver models. Each model unpacks JSONB into typed columns, applies data quality fixes, generates surrogate keys, and upserts records by natural key. Only records with a new `ingest_timestamp` are processed on each run.

**Stage 4: Enrich (Gold)**
dbt runs 12 gold_operations models — 9 dimensions, 3 fact tables, and 1 ETL support table. Dimensions are rebuilt as tables on each run. Fact tables are incremental, appending only new records from silver.

**Stage 5: Test**
dbt runs 42 data quality tests validating primary key uniqueness, not-null constraints, and foreign key relationships across the full gold layer.

---

## 📡 **Data Sources**

All six source systems were synthetically generated to mirror real API responses including documented data quality quirks. Historical data covers January 2025 to June 2025. Incremental data is generated weekly by the simulator.

### Source Data Summary

| System | Entities | Records (Historical) | Key Quirks Built In |
|---|---|---|---|
| **Onfleet** | Tasks, Workers | 87,174 tasks, 48 workers | Millisecond epoch timestamps, `[lng, lat]` coordinate order, null worker on unassigned tasks, metadata array per task |
| **Linnworks** | Orders, Inventory, Stock Transactions | 30,939 orders, 292 SKUs, 56,167 transactions | SKU inconsistency (hyphen vs underscore), negative stock levels, orphaned transaction references, duplicate product records |
| **QuickBooks** | Invoices, Payments, Expenses | 564 invoices, 418 payments, 1,300+ expenses | No delivery IDs on invoice lines, partial payments, CustomField array for client ID, billing period |
| **Gusto** | Employees, Payroll Runs, Compensations | 62 employees, 13 payroll runs, 806 compensation records | One terminated driver canonical across all systems, employee compensations as nested array per payroll |
| **Samsara** | Vehicles, Trips, Driver Summary | 35 vehicles, cumulative trip data, 48 driver summaries | Epoch ms timestamps, trip overlap prevention, idle time as separate duration field |
| **Salesforce** | Accounts, Contracts, Contract Rates, Opportunities | 94 accounts, 94 contracts, 1,315 rate records, 57 opportunities | Rate cards in separate custom object, 3 contracts with null AccountId, stale LastActivityDate on some records |

### Why Quirks Were Intentionally Included

> The learning value of this project is in handling messy, real-world data — not in processing clean, idealised records. Every quirk listed above is documented behaviour from the real API of that system. Practicing on this data means encountering these problems in a safe environment before meeting them with a real client.

---

## 🗄️ **Data Warehouse Design**

![SwiftRoute Physical ERD](images/SwiftRoute%20Physical%20ERD.png)

### Schema Design: Star Schema (Galaxy)

The gold layer uses a **star schema with conformed dimensions**, meaning dimension tables are shared across multiple fact tables. This enables cross-fact analysis — for example, joining delivery performance to invoice revenue through the shared `dim_client` and `dim_date` dimensions.

### Fact Tables

| Table | Grain | Primary Purpose |
|---|---|---|
| `fact_delivery` | One row per Onfleet delivery task | Core operational and financial delivery record combining Onfleet, Samsara, Gusto, and Salesforce |
| `fact_inventory_transaction` | One row per Linnworks stock movement event | Inventory flow, reconciliation, and stock level reconstruction |
| `fact_invoice` | One row per QuickBooks invoice | Billing, accounts receivable, and revenue tracking |

### Dimension Tables

| Table | Description | Source |
|---|---|---|
| `dim_date` | Generated date spine (2024 to 2026), shared across all facts | Generated (no source) |
| `dim_client` | Client profiles, tiers, contract terms | Salesforce accounts and contracts |
| `dim_driver` | Driver identity with cross-system ID resolution | Onfleet workers, Gusto employees, Samsara driver summary |
| `dim_vehicle` | Vehicle attributes and operational status | Samsara vehicles |
| `dim_zone` | Delivery zones per city derived from metadata | Onfleet delivery metadata, Salesforce contract rates |
| `dim_sku` | Product catalogue for fulfillment clients | Linnworks inventory (surviving records only) |
| `dim_service_type` | Service tiers with SLA hours and pricing tier | Onfleet delivery metadata, Salesforce contract rates |
| `dim_contract_rate` | Per-client, per-zone, per-service pricing | Salesforce contract rates |

### ETL Support Tables (not part of the star schema)

| Table | Purpose |
|---|---|
| `driver_id_map` | Resolves Onfleet worker ID, Gusto UUID, and Samsara driver ID to a single canonical driver key. Used during ETL only. |
| `bronze.pipeline_state` | Tracks which source files have been loaded. Enables true incremental loading without reprocessing historical data. |

---

## ⚙️ **ETL and Load Strategy**

### Extraction

| Approach | Description |
|---|---|
| **Incremental by file** | Each loader checks `bronze.pipeline_state` before processing any file. Files already recorded are skipped. New files are loaded and recorded. |
| **First run behaviour** | All files are unprocessed on the first run, so the first run is a full load in practice. Subsequent runs pick up only new files. |
| **Run order dependency** | Onfleet must run before Samsara. Samsara trips are derived from Onfleet tasks. All other loaders are independent. |

### Load Method by Layer

| Layer | Method | dbt Materialisation | Rationale |
|---|---|---|---|
| **Bronze** | Append only | Raw table (Python loader) | Non-volatile archive. Records are never updated or deleted. Provides a complete audit trail. |
| **Silver** | Upsert by natural key | `incremental` (merge) | Reflects corrections arriving from source while preserving history via `record_hash_key`. |
| **Gold Dimensions** | Full rebuild each run | `table` | Small tables, cheap to rebuild, always reflect current state. |
| **Gold Facts** | Incremental append | `incremental` | Large tables. Only new records from silver are processed on each run. |

### Pipeline Execution Order (Airflow DAG)

```
simulate_new_data
      |
      v
load_onfleet
      |
      |-----> load_samsara
      |-----> load_gusto
      |-----> load_linnworks
      |-----> load_quickbooks
      |-----> load_salesforce
                    |
                    v
             dbt_run_silver
                    |
                    v
              dbt_run_gold
                    |
                    v
             dbt_test_gold
```

---

## 📁 **Folder Structure**

```
swiftroute_ods/
|
|-- .env                              # Database credentials (never committed)
|-- .gitignore
|-- .python-version
|-- docker-compose.yaml               # Airflow and PostgreSQL container definitions
|-- pyproject.toml                    # uv-managed Python dependencies
|-- uv.lock
|-- README.md
|
|-- images/                           # Project diagrams and architecture visuals
|   |-- Data Architecture.png
|   |-- Data Flow Diagram.png
|   |-- SwiftRoute Physical ERD.png
|
|-- generators/                       # Scripts that produce the full historical dataset
|   |-- generate_shared_ids.py        # Step 0: generates master data (drivers, vehicles, clients, zones)
|   |-- shared_ids.py                 # Exported master data used by all generators
|   |-- generate_onfleet.py
|   |-- generate_samsara.py           # Must run after generate_onfleet.py
|   |-- generate_gusto.py
|   |-- generate_linnworks.py
|   |-- generate_quickbooks.py
|   |-- generate_salesforce.py
|
|-- simulators/                       # Scripts that produce incremental (weekly) data batches
|   |-- _common.py                    # Shared helpers: date resolution, page continuation
|   |-- run_simulation.py             # Master script: run this to advance the pipeline by 7 days
|   |-- simulate_onfleet.py
|   |-- simulate_samsara.py
|   |-- simulate_gusto.py
|   |-- simulate_linnworks.py
|   |-- simulate_quickbooks.py
|   |-- simulate_salesforce.py
|
|-- source_data/                      # Raw JSON files (git-ignored, regenerate locally)
|   |-- raw/
|       |-- onfleet/
|       |-- linnworks/
|       |-- quickbooks/
|       |-- gusto/
|       |-- samsara/
|       |-- salesforce/
|
|-- loaders/                          # Python scripts: JSON files to PostgreSQL bronze
|   |-- __init__.py
|   |-- load_onfleet.py
|   |-- load_samsara.py
|   |-- load_gusto.py
|   |-- load_linnworks.py
|   |-- load_quickbooks.py
|   |-- load_salesforce.py
|
|-- dbt_project/                      # All dbt transformation logic
|   |-- dbt_project.yml               # Project config: schema names, materialisation defaults
|   |-- profiles.yml                  # Database connection config (warehouse connection)
|   |-- macros/
|   |   |-- generate_schema_name.sql  # Overrides dbt default schema naming behaviour
|   |-- models/
|   |   |-- sources.yml               # Declares all 18 bronze tables as dbt sources
|   |   |-- silver/                   # 18 cleaned and standardised models
|   |   |-- gold_operations/          # 9 dimensions + 3 fact tables + 1 support table
|   |       |-- schema.yml            # PK, FK, not_null, and uniqueness tests
|   |-- analyses/                     # Exploratory SQL for each bronze table (not materialised)
|   |-- seeds/
|   |-- snapshots/
|   |-- tests/
|
|-- airflow/                          # Airflow orchestration
|   |-- dags/
|   |   |-- swiftroute_pipeline_dag.py
|   |-- config/
|   |-- plugins/
|
|-- logs/                             # dbt run logs (git-ignored)
```

---

## 🏷️ **Naming Conventions**

### Schema Names

| Schema | Purpose |
|---|---|
| `bronze` | Raw JSONB records loaded by Python loaders |
| `silver` | Cleaned, typed, standardised dbt models |
| `gold_operations` | Star schema: fact and dimension tables |

### Model Names

| Layer | Pattern | Example |
|---|---|---|
| Silver | `silver_{source_system}_{entity}` | `silver_onfleet_deliveries` |
| Gold Dimensions | `dim_{entity}` | `dim_driver` |
| Gold Facts | `fact_{process}` | `fact_delivery` |
| ETL Support | descriptive name | `driver_id_map` |

### Surrogate Key Prefixes

Each silver and gold model generates a human-readable surrogate key using a short prefix and a zero-padded integer.

| Table | Prefix | Example |
|---|---|---|
| `silver_onfleet_deliveries` | `del_` | `del_00001` |
| `silver_onfleet_workers` | `worker_id` (natural, already readable) | `drv_fte_001` |
| `silver_gusto_employees` | `emp_` | `emp_00001` |
| `silver_gusto_payroll_runs` | `pay_` | `pay_00001` |
| `silver_gusto_payroll_compensations` | `cmp_` | `cmp_00001` |
| `silver_linnworks_inventory` | `inv_` | `inv_00001` |
| `silver_linnworks_orders` | `ord_` | `ord_000001` |
| `silver_linnworks_stock_transactions` | `txn_` | `txn_000001` |
| `silver_quickbooks_invoices` | `inv_qb_` | `inv_qb_00001` |
| `silver_quickbooks_payments` | `pmt_` | `pmt_00001` |
| `silver_quickbooks_expenses` | `exp_` | `exp_00001` |
| `silver_salesforce_accounts` | `acc_` | `acc_00001` |
| `silver_salesforce_contracts` | `con_` | `con_00001` |
| `silver_salesforce_contract_rates` | `rat_` | `rat_00001` |
| `silver_salesforce_opportunities` | `opp_` | `opp_00001` |
| `silver_samsara_vehicles` | `vehicle_` (prefix `veh_`) | `veh_00001` |
| `silver_samsara_trips` | `trp_` | `trp_000001` |
| `silver_samsara_driver_summary` | `drs_` | `drs_00001` |

### SQL Style

All SQL in dbt models follows these conventions:

- Keywords in UPPERCASE (`SELECT`, `FROM`, `WHERE`, `CASE`, `WHEN`)
- Column aliases right-aligned using spaces for readability
- Each major transformation stage in a named CTE (`source`, `unpacked`, `cleaned`, `derived`, `final`)
- Section headers as block comments (`-- ===== SECTION 1: SOURCE =====`)
- No em dashes in comments — use colons or commas instead
- All timestamps cast to `TIMESTAMPTZ` (never plain `TIMESTAMP`)
- Empty strings converted to NULL via `NULLIF(TRIM(col), '')`

### File Names

| Type | Pattern | Example |
|---|---|---|
| Loader scripts | `load_{source_system}.py` | `load_onfleet.py` |
| Generator scripts | `generate_{source_system}.py` | `generate_gusto.py` |
| Simulator scripts | `simulate_{source_system}.py` | `simulate_linnworks.py` |
| Analysis files | `explore_{table_name}.sql` | `explore_onfleet_deliveries.sql` |

---

## 📖 **Data Catalogue**

### Bronze Layer

All bronze tables share the same structure: three loader-added metadata columns plus one JSONB column holding the full raw record.

| Column | Type | Description |
|---|---|---|
| `id` | SERIAL | Auto-incrementing bronze row ID |
| `ingest_timestamp` | TIMESTAMP | When the loader inserted this record |
| `source_file` | VARCHAR | Relative path of the source JSON file |
| `raw_data` | JSONB | Full raw record exactly as received from source |

**Bronze tables (18 total):**

| Table | Source System | Records (Historical) |
|---|---|---|
| `bronze.onfleet_deliveries` | Onfleet Tasks API | 87,174 |
| `bronze.onfleet_workers` | Onfleet Workers API | 48 |
| `bronze.linnworks_orders` | Linnworks Orders API | 30,939 |
| `bronze.linnworks_inventory` | Linnworks Stock Items API | 292 |
| `bronze.linnworks_stock_transactions` | Linnworks Transactions API | 56,167 |
| `bronze.quickbooks_invoices` | QuickBooks Invoice API | 564 |
| `bronze.quickbooks_payments` | QuickBooks Payment API | 418 |
| `bronze.quickbooks_expenses` | QuickBooks Purchase API | 1,300+ |
| `bronze.gusto_employees` | Gusto Employees API | 62 |
| `bronze.gusto_payroll_runs` | Gusto Payroll API | 13 |
| `bronze.gusto_payroll_compensations` | Gusto Payroll API | 806 |
| `bronze.salesforce_accounts` | Salesforce Accounts API | 94 |
| `bronze.salesforce_contracts` | Salesforce Contracts API | 94 |
| `bronze.salesforce_contract_rates` | Salesforce Contract Rates API | 1,315 |
| `bronze.salesforce_opportunities` | Salesforce Opportunities API | 57 |
| `bronze.samsara_vehicles` | Samsara Vehicles API | 35 |
| `bronze.samsara_trips` | Samsara Trips API | Cumulative |
| `bronze.samsara_driver_summary` | Samsara Driver Summary API | 48 |

### Silver Layer

All silver models add these standard metadata columns in addition to their unpacked, typed columns:

| Column | Type | Description |
|---|---|---|
| `{entity}_sk` | VARCHAR | Human-readable surrogate key (e.g. `del_00001`) |
| `record_hash_key` | VARCHAR | MD5 hash of full row for incremental upsert and change detection |
| `silver_loaded_at` | TIMESTAMPTZ | When this record was last written to silver |
| `silver_source_model` | VARCHAR | Which dbt model created this row |

**Silver models (18 total):**

| Model | Key Fix Applied | Natural Key | Rows (Historical) |
|---|---|---|---|
| `silver.silver_onfleet_deliveries` | Epoch ms to TIMESTAMPTZ, last_modified_at fix, delivery_status derived, completion_success derived, metadata array unpacked by name | `delivery_source_id` | 87,174 |
| `silver.silver_onfleet_workers` | Employment type from metadata array, city derived from team name | `worker_id` | 48 |
| `silver.silver_linnworks_orders` | Phone normalisation to +1-XXX-XXX-XXXX, reference number regenerated as LWO sequence, SKU normalised | `order_source_id` | 30,939 |
| `silver.silver_linnworks_inventory` | SKU normalisation (UPPER, hyphens only), duplicate resolution (earliest creation_date survives), modified_date fix | `stock_item_source_id` | 292 |
| `silver.silver_linnworks_stock_transactions` | SKU normalisation, resolved to surviving inventory record via normalised_sku join | `transaction_source_id` | 56,167 |
| `silver.silver_quickbooks_invoices` | CustomField array unpacked by name, payment terms derived, overdue flag derived | `invoice_source_id` | 564 |
| `silver.silver_quickbooks_payments` | CustomField array unpacked by name, linked_invoice_id extracted from Line array | `payment_source_id` | 418 |
| `silver.silver_quickbooks_expenses` | Expense category derived from account name via ILIKE matching | `expense_source_id` | 1,300+ |
| `silver.silver_gusto_employees` | full_name derived for cross-system joins, years_of_service computed, is_active derived | `employee_source_id` | 62 |
| `silver.silver_gusto_payroll_runs` | check_date_lag_days derived, total_labour_cost derived, effective tax rate derived | `payroll_source_id` | 13 |
| `silver.silver_gusto_payroll_compensations` | Joined to employees and payroll runs, effective_hourly_rate derived | Composite: employee_source_id + payroll_source_id | 806 |
| `silver.silver_salesforce_accounts` | last_activity_date fix (cannot precede created_at), days_since_last_activity derived | `account_source_id` | 94 |
| `silver.silver_salesforce_contracts` | is_active derived from status and end_date, days_remaining derived | `contract_source_id` | 94 |
| `silver.silver_salesforce_contract_rates` | net_rate_discrepancy_flag, computed_net_rate derived | `rate_source_id` | 1,315 |
| `silver.silver_salesforce_opportunities` | last_activity_date fix, is_won/is_closed/is_open derived, weighted_amount derived | `opportunity_source_id` | 57 |
| `silver.silver_samsara_vehicles` | ownership derived from vehicle_type, city derived from tags | `vehicle_id` | 35 |
| `silver.silver_samsara_trips` | Epoch ms to TIMESTAMPTZ, duration/distance/fuel efficiency derived, safety event count derived | `trip_source_id` | Cumulative |
| `silver.silver_samsara_driver_summary` | Durations converted to hours, safety score band derived, idle percentage derived | `driver_source_id` | 48 |

### Gold Operations Layer

**Dimensions (9 tables):**

| Table | PK | Rows | Description |
|---|---|---|---|
| `gold_operations.dim_date` | `date_key` (INT) | 1,096 | Generated date spine 2024 to 2026 |
| `gold_operations.dim_client` | `client_key` (VARCHAR) | 94 | Client profiles and active contract terms |
| `gold_operations.dim_driver` | `driver_key` (VARCHAR) | 48 | Cross-system driver identity and attributes |
| `gold_operations.dim_vehicle` | `vehicle_key` (VARCHAR) | 35 | Fleet asset attributes and status |
| `gold_operations.dim_zone` | `zone_key` (VARCHAR) | 17 | Delivery zones across 3 cities |
| `gold_operations.dim_sku` | `sku_key` (VARCHAR) | 274 | Product catalogue (surviving records only) |
| `gold_operations.dim_service_type` | `service_type_key` (VARCHAR) | 7 | Service tiers with SLA and pricing attributes |
| `gold_operations.dim_contract_rate` | `contract_rate_key` (VARCHAR) | 1,314 | Per-client, per-zone, per-service rate cards |
| `gold_operations.driver_id_map` | `canonical_driver_key` (VARCHAR) | 48 | ETL support: cross-system driver ID resolution |

**Fact Tables (3 tables):**

| Table | PK | Grain | Rows (Historical) |
|---|---|---|---|
| `gold_operations.fact_delivery` | `delivery_id` | One row per Onfleet delivery task | 87,174 |
| `gold_operations.fact_inventory_transaction` | `inventory_txn_id` | One row per Linnworks stock movement | 56,167 |
| `gold_operations.fact_invoice` | `invoice_id` | One row per QuickBooks invoice | 564 |

---

## 🛠️ **Tech Stack**

| Tool | Version | Role |
|---|---|---|
| **Python** | 3.13 | Data generation, incremental simulation, loader scripts |
| **PostgreSQL** | 16 | Data warehouse: hosts bronze, silver, and gold_operations schemas |
| **dbt (dbt-postgres)** | 1.11 | Transformation layer: bronze to silver to gold |
| **Apache Airflow** | 2.10.5 | Pipeline orchestration: schedules and monitors the full DAG |
| **Docker + Compose** | Latest | Containerises Airflow (webserver + scheduler) and both PostgreSQL instances |
| **uv** | Latest | Python package and virtual environment management |
| **Faker** | 40.28+ | Synthetic data generation: realistic names, addresses, companies |
| **psycopg2-binary** | 2.9.12+ | PostgreSQL connection adapter for Python loaders |
| **python-dotenv** | 1.2.2+ | Environment variable management |

---

## 🚀 **How to Run**

### Prerequisites

- Python 3.13+
- Docker Desktop with WSL2 backend (Windows) or Docker Engine (Linux/Mac)
- uv (`pip install uv`)
- Git

### 1. Clone the repository

```bash
git clone https://github.com/your-username/swiftroute_ods.git
cd swiftroute_ods
```

### 2. Install Python dependencies

```bash
uv sync
source .venv/Scripts/activate   # Windows (Git Bash)
# or
source .venv/bin/activate        # Mac/Linux
```

### 3. Configure environment variables

Create a `.env` file at the project root:

```
DB_HOST=localhost
DB_PORT=5433
DB_NAME=swiftroute_data_warehouse
DB_USER=swiftroute
DB_PASSWORD=swiftroute
```

### 4. Start Docker containers

This starts Airflow (webserver + scheduler) and two PostgreSQL instances (Airflow internal + data warehouse):

```bash
docker compose up -d
```

Wait approximately 60 seconds for all services to be healthy.

### 5. Create database schemas

```bash
docker exec -it swiftroute_ods-postgres-warehouse-1 psql -U swiftroute -d swiftroute_data_warehouse -c "
CREATE SCHEMA IF NOT EXISTS bronze;
CREATE SCHEMA IF NOT EXISTS silver;
CREATE SCHEMA IF NOT EXISTS gold_operations;
CREATE TABLE IF NOT EXISTS bronze.pipeline_state (
    id              SERIAL PRIMARY KEY,
    source_system   VARCHAR   NOT NULL,
    source_file     VARCHAR   NOT NULL,
    loaded_at       TIMESTAMP NOT NULL DEFAULT NOW(),
    record_count    INTEGER   NOT NULL,
    UNIQUE (source_system, source_file)
);
"
```

### 6. Generate historical source data

Run the generators in this order (Onfleet before Samsara is required):

```bash
uv run python generators/generate_shared_ids.py
uv run python generators/generate_onfleet.py
uv run python generators/generate_samsara.py
uv run python generators/generate_gusto.py
uv run python generators/generate_linnworks.py
uv run python generators/generate_quickbooks.py
uv run python generators/generate_salesforce.py
```

### 7. Load historical data into bronze

```bash
uv run python loaders/load_onfleet.py
uv run python loaders/load_samsara.py
uv run python loaders/load_gusto.py
uv run python loaders/load_linnworks.py
uv run python loaders/load_quickbooks.py
uv run python loaders/load_salesforce.py
```

### 8. Run dbt transformations

```bash
cd dbt_project
uv run dbt run --select silver.*
uv run dbt run --select gold_operations.*
uv run dbt test --select gold_operations.*
```

### 9. Run the full pipeline via Airflow

Open the Airflow UI at `http://localhost:8081` (username: `admin`, password: `admin`).

Enable the `swiftroute_pipeline` DAG and trigger a manual run. The DAG handles simulation, loading, silver, gold, and testing in the correct order.

To run the next incremental batch manually without Airflow:

```bash
uv run simulators/run_simulation.py
uv run python loaders/load_onfleet.py && uv run python loaders/load_samsara.py && uv run python loaders/load_gusto.py && uv run python loaders/load_linnworks.py && uv run python loaders/load_quickbooks.py && uv run python loaders/load_salesforce.py
cd dbt_project && uv run dbt run --select silver.* && uv run dbt run --select gold_operations.*
```

---

## 📊 **Project Status**

| Phase | Status | Description |
|---|---|---|
| Business context and source system analysis | ✅ Complete | SwiftRoute operating context, 6 source systems documented with quirks |
| Conceptual and logical ERD | ✅ Complete | 11 entities, 4 groups, star schema designed |
| Physical ERD | ✅ Complete | Full column definitions, PKs, FKs, data types |
| Synthetic data generation | ✅ Complete | 6 generators producing 87K+ historical records across 6 systems |
| Incremental simulator | ✅ Complete | 6 simulators producing weekly incremental batches |
| Bronze schema and loaders | ✅ Complete | 18 bronze tables, 6 loader scripts with pipeline_state tracking |
| Silver dbt models (18) | ✅ Complete | All data quality fixes applied, surrogate keys generated, incremental upserts |
| Gold operations models (12) | ✅ Complete | 9 dimensions, 3 fact tables, 42 data quality tests passing |
| Airflow DAG orchestration | ✅ Complete | Full pipeline DAG with correct dependency order and retry logic |
| Phase 2: Analytics and Dashboarding | ⏳ Planned | Power BI dashboards answering the 5 root operational questions |

---

## ⚠️ **Known Limitations and Design Decisions**

**Simulation scope:**
Source data is static JSON files on disk, not live API connections. The simulator produces realistic incremental batches but does not simulate all possible API behaviours (webhook events, real-time updates, API pagination edge cases).

**Driver labour cost approximation:**
`fact_delivery.driver_labour_cost` is derived by dividing a driver's bi-weekly gross pay by their delivery count for that pay period. This is an approximation. A production implementation would require per-shift or per-hour timekeeping data not available in the simulation.

**Zone approximation in fact_inventory_transaction:**
Linnworks stock transactions do not carry a zone ID. Zone is approximated from the warehouse location name mapped to the first zone in that city. This is documented in the model and is the best approximation available from the source data.

**Samsara trip boundary:**
A small number of Samsara trips legitimately end in early July 2025 due to late-June deliveries completing past midnight. This is not a data quality error and is handled correctly by the pipeline, which does not hardcode month ranges.

**Surrogate key stability:**
Surrogate keys are generated using `ROW_NUMBER()` ordered by natural key. On a `--full-refresh`, the integer sequence is stable as long as no records are deleted from bronze. If bronze records are purged, surrogate keys should be regenerated and downstream joins verified.

**Cross-system driver identity:**
The `driver_id_map` resolves cross-system identity by matching on full driver name. This is robust for this simulation where names are consistent across systems. In a real client engagement, a shared employee ID or HR system integration would be the correct approach.

---

## 🔭 **Next Phase**

Phase 2 of this project will connect the gold layer to a dashboarding tool and build operational reports answering the five root questions:

1. **Delivery Performance Dashboard**: on-time rate, SLA achievement, failure analysis by driver and zone
2. **Revenue and Billing Dashboard**: monthly revenue, invoice status, AR ageing by client
3. **Cost and Margin Dashboard**: cost per delivery, driver labour cost, margin by client and zone
4. **Fleet and Driver Utilisation Dashboard**: vehicle efficiency, driver performance, safety scoring
5. **Inventory and Fulfillment Dashboard**: stock movement, transaction types, client inventory health

Phase 2 will be developed as a separate project repository linked from here.

---

*This project is a simulation built for learning and portfolio purposes. SwiftRoute Logistics is a fictional company. All data is synthetically generated and does not represent any real business or individual.*

---
## 🕵️‍♂️ **About Me**

I'm Ehijele David, I design structured data foundation for Small & Meduim Businesses that makes operations visible, and decision-making reliable <br>
You can connect with me via:
<br>
<a href="https://www.linkedin.com/in/ehijeledavid/">
  <img src="https://cdn-icons-png.flaticon.com/512/174/174857.png" width="25" height="25" />
</a>&nbsp;
<a href="https://x.com/insights_orbit">
  <img src="https://cdn-icons-png.flaticon.com/512/5969/5969020.png" width="25" height="25" />
</a>&nbsp;