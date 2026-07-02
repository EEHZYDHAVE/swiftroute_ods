# 🚚 SwiftRoute Logistics Operational Data System

> **A simulated end-to-end data engineering project** building a production-grade Operational Data System (ODS) for a regional last-mile delivery and fulfillment company. Built using PostgreSQL, dbt, and Apache Airflow on the medallion architecture.

---

## 📋 Table of Contents

- [Project Context](#-project-context)
- [The Business SwiftRoute Logistics](#-the-business--swiftroute-logistics)
- [The Problem Being Solved](#-the-problem-being-solved)
- [What Is an Operational Data System?](#-what-is-an-operational-data-system)
- [Architecture Overview](#-architecture-overview)
- [Data Sources](#-data-sources)
- [Data Warehouse Design](#-data-warehouse-design)
- [Folder Structure](#-folder-structure)
- [ETL Strategy](#-etl-strategy)
- [Tech Stack](#-tech-stack)
- [Project Status](#-project-status)
- [How to Run](#-how-to-run)

---

## 🎯 Project Context

This project is a **simulated real-world engagement** built as a learning prototype for delivering Operational Data Systems (ODS) to SMB and startup founders. The simulation mirrors the exact workflow a practitioner would follow with a real client:

1. Understand the business and its operating reality
2. Map the core operational entities that drive revenue, cost, risk, and control
3. Analyse source systems to understand where data is born and how it flows
4. Design the data warehouse schema (conceptual → logical → physical ERD)
5. Build the extraction, transformation, and loading pipeline
6. Surface the data in dashboards that answer specific operational questions

The business chosen for the simulation is **SwiftRoute Logistics** — a regional last-mile delivery and fulfillment company operating across three cities in North America. All data is **synthetically generated** and mirrors the exact JSON structures returned by the real APIs of each source system, including documented data quality quirks.

---

## 🏢 The Business — SwiftRoute Logistics

SwiftRoute Logistics is a **mixed last-mile carrier and fulfillment operation** founded in Denver, Colorado in 2018. It serves 94 active business accounts ranging from e-commerce brands and retail chains to healthcare distributors and B2B corporate clients.

### What SwiftRoute Does

| Service | Description |
|---|---|
| Same-Day Delivery | Orders submitted before 11 AM delivered within 4 hours |
| Next-Day Delivery | Orders accepted until 6 PM delivered next business day |
| Scheduled / Window Delivery | Client-specified delivery windows for B2B and healthcare |
| E-Commerce Fulfillment | Warehouse storage, pick-and-pack, and dispatch for 11 clients |
| Returns Management | Collection and restocking of customer returns |
| B2B Distribution Runs | Scheduled multi-stop routes for retail and FMCG clients |

### Operating Scale (June 2025)

- **~380 deliveries per day** across Denver, Salt Lake City, and Albuquerque
- **48 drivers** (32 FTE, 16 independent contractors)
- **36 vehicles** — cargo vans, motorcycles, and box trucks
- **94 active business accounts** (9 Platinum, 28 Gold, 57 Standard)
- **11 fulfillment clients** with inventory stored in the Denver warehouse
- **18,000 sq ft** warehouse facility in Denver

### Technology Stack (Source Systems)

| System | Purpose |
|---|---|
| **Onfleet** | Transport Management System — orders, dispatch, delivery tracking |
| **Linnworks** | Warehouse Management System — inventory, fulfillment orders |
| **QuickBooks Online** | Finance — invoicing, payments, expenses |
| **Gusto** | Payroll — FTE employee compensation |
| **Samsara** | Fleet Management — GPS tracking, fuel, driver safety |
| **Salesforce** | CRM — client accounts, contracts, rate cards |

---

## ❗ The Problem Being Solved

SwiftRoute operates across six software platforms. **None of them are integrated with each other.** Each system knows one slice of the business and nothing else.

This fragmentation means the leadership team cannot answer the questions that matter most:

| Question | Why It Cannot Be Answered Today |
|---|---|
| What is our on-time delivery rate by zone and driver? | Pickup timestamps are inconsistently captured in Onfleet and have never been joined to SLA windows |
| What does it actually cost us to make a delivery? | Driver pay (Gusto), fuel (Samsara), and delivery volume (Onfleet) have never been connected |
| Which clients are profitable after accounting for operational burden? | Revenue lives in QuickBooks; cost lives in Gusto and Samsara; no system connects them |
| What is our actual monthly revenue? | Billing is calculated manually from Onfleet exports — a 3 to 5 day process every month-end |
| Which drivers are underperforming? | No single view combining completion rate, SLA achievement, and failure reasons per driver |

The root cause is not that the data does not exist. **The data exists — across six systems — but has never been assembled into a single analytical layer.** The ODS closes that gap.

---

## 💡 What Is an Operational Data System?

An **Operational Data System (ODS)** is a lightweight data infrastructure designed specifically for the scale and operational reality of SMBs and startups that:

- Captures daily business activity from source systems
- Moves that data through automated transformation pipelines
- Surfaces it in dashboards and reports that founders and operators can use to make decisions

> *"ODS is the analytical layer built around the core operational entities of the business that directly produce revenue, cost, risk, and control."*

## 🏗️ Architecture Overview

This project implements the **Medallion Architecture** on PostgreSQL, with dbt handling all transformation logic and Airflow orchestrating the pipeline.

```
SOURCE DATA          BRONZE              SILVER              GOLD
(JSON files)    →  (raw tables)   →  (cleaned tables) →  (star schema)

Onfleet ──────┐
Linnworks ────┤
QuickBooks ───┼──► bronze.*  ──►  silver.*  ──►  fact_delivery
Gusto ────────┤                              ──►  fact_inventory_transaction
Samsara ──────┤                              ──►  fact_invoice
Salesforce ───┘                              ──►  dim_client / dim_driver / etc.
```

### The Three Layers Explained

| Layer | What It Contains | How It's Built |
|---|---|---|
| **Bronze** | Raw records exactly as they arrived from source — no transformation, JSONB format | Python loader scripts |
| **Silver** | Cleaned, standardised, typed records — one table per source entity | dbt models (incremental) |
| **Gold** | Star schema — fact and dimension tables built around core operational entities | dbt models (table + incremental) |

### The Five Root Questions the Gold Layer Answers

1. **Are we keeping our promises to clients?** → On-time rate, SLA achievement, failure analysis
2. **Are we capturing all the revenue our operations generate?** → Billing accuracy, revenue by client
3. **What does it actually cost us to serve each part of the business?** → Cost per delivery, margin by zone
4. **How effectively are we deploying our operational capacity?** → Driver utilisation, vehicle efficiency
5. **Where is operational risk concentrated?** → AR aging, COD leakage, driver compliance

---

## 📡 Data Sources

All six source systems have been **synthetically generated** to mirror real API responses including documented data quality quirks. The data covers January 2025 to June 2025.

### Source Data Summary

| System | Records Generated | Key Quirks Built In |
|---|---|---|
| **Onfleet** | 86,916 tasks across 1,362 pages | Millisecond timestamps, `[lng, lat]` coordinate order, null worker on unassigned tasks, batch completion timestamps, missing metadata on manual entries |
| **Linnworks** | 238 SKUs, ~3,400 orders/month, stock transactions | SKU inconsistency (hyphen vs underscore), negative stock levels, orphaned transaction references |
| **QuickBooks** | 564 invoices, ~418 payments, monthly expenses | No delivery IDs on invoice lines, partial payments, COD as lump deposits, fuel miscoded as maintenance |
| **Gusto** | 62 employees, 13 bi-weekly payrolls | All money values as strings, bonuses in separate array, employer taxes separate from gross pay, terminated employees |
| **Samsara** | 35 vehicles, trips per vehicle per month | Named `{latitude, longitude}` vs Onfleet's `[lng, lat]`, idle time inflating duration, some trips with null driverId |
| **Salesforce** | 94 accounts, 94 contracts, 1,315+ rate records | Rate card in separate custom object, compound BillingAddress field, 3 orphaned contracts, stale LastActivityDate |

### Why Quirks Were Intentionally Included

> The learning value of this project is in handling messy, real-world data — not in processing clean, idealised records. Every quirk listed above is documented behaviour from the real API of that system. Practicing on this data means encountering these problems in a safe environment before meeting them with a real client.

---

## 🗄️ Data Warehouse Design

### Core Operational Entities

The gold layer is built around **11 core operational entities** — the things in the business that directly produce revenue, cost, risk, and control:

| Entity | Group | Source Systems |
|---|---|---|
| Customer | Commercial | Salesforce, QuickBooks |
| Order | Operational | Onfleet, Linnworks |
| Delivery | Operational | Onfleet |
| Driver | Resource | Onfleet, Gusto, Samsara |
| Vehicle | Resource | Samsara |
| Zone | Operational | Onfleet (metadata), Salesforce |
| Route | Operational | Onfleet |
| Fulfillment Order | Fulfillment | Linnworks |
| Inventory | Fulfillment | Linnworks |
| Invoice | Commercial | QuickBooks, Salesforce |
| Payment | Commercial | QuickBooks |

### Schema Design — Star Schema (Galaxy)

The gold layer uses a **star schema with conformed dimensions**, which means dimension tables are shared across multiple fact tables.

**Fact Tables**

| Table | Grain | Primary Purpose |
|---|---|---|
| `fact_delivery` | One row per delivery event | Core operational + financial delivery record |
| `fact_inventory_transaction` | One row per stock movement | Inventory flow and reconciliation |
| `fact_invoice` | One row per invoice line item | Billing and accounts receivable |

**Dimension Tables**

| Table | Description |
|---|---|
| `dim_date` | One row per calendar day — shared across all fact tables |
| `dim_client` | Client profiles, tiers, and contract attributes |
| `dim_driver` | Driver identity with cross-system ID mapping |
| `dim_vehicle` | Vehicle attributes and operational status |
| `dim_zone` | Delivery zones per city with surcharge metadata |
| `dim_service_type` | Service types with base SLA hours |
| `dim_sku` | Product catalogue for fulfillment clients |
| `dim_contract_rate` | Authoritative per-client, per-zone, per-service pricing |
| `dim_courier_partner` | Third-party overflow carrier attributes |

**ETL Support Tables** *(not part of the star schema)*

| Table | Purpose |
|---|---|
| `driver_id_map` | Resolves Onfleet / Gusto / Samsara IDs to one canonical driver key |
| `pipeline_state` | Tracks which source files have been loaded (incremental control) |

### Physical ERD

> *Image to be added — see `docs/SwiftRoute_Physical_ERD.png`*

---

## 📁 Folder Structure

```
SWIFTROUTE_ODS/
│
├── .env                          # Database credentials — never committed
├── .gitignore
├── README.md
├── pyproject.toml                # uv-managed dependencies
├── uv.lock
│
├── generators/                   # Scripts that create synthetic source data
│   ├── generate_onfleet.py
│   ├── generate_linnworks.py
│   ├── generate_quickbooks.py
│   ├── generate_gusto.py
│   ├── generate_samsara.py
│   └── generate_salesforce.py
│
├── source_data/                  # Raw JSON files (git-ignored — regenerate locally)
│   ├── onfleet/
│   ├── linnworks/
│   ├── quickbooks/
│   ├── gusto/
│   ├── samsara/
│   └── salesforce/
│
├── loaders/                      # Python scripts: JSON files → PostgreSQL bronze
│   ├── load_onfleet.py
│   ├── load_linnworks.py
│   ├── load_quickbooks.py
│   ├── load_gusto.py
│   ├── load_samsara.py
│   └── load_salesforce.py
│
├── db/
│   └── schema.sql                # CREATE SCHEMA statements and extensions
│
├── dbt_project/                  # All transformation logic
│   ├── dbt_project.yml
│   ├── models/
│   │   ├── bronze/               # Views over raw bronze tables
│   │   ├── silver/               # Cleaned and standardised models
│   │   └── gold/                 # Star schema — facts and dimensions
│   └── sources.yml               # Declares bronze tables as dbt sources
│
├── airflow/                      # Pipeline orchestration
│   ├── dags/
│   │   └── swiftroute_pipeline_dag.py
│   └── docker-compose.yaml
│
└── docs/                         # Project documentation and diagrams
    ├── SwiftRoute_Conceptual_ERD.png
    ├── SwiftRoute_Logical_ERD.png
    └── SwiftRoute_Physical_ERD.png
```

---

## ⚙️ ETL Strategy

### Extraction

| Source | Method | Notes |
|---|---|---|
| All sources | **Incremental by file** | Loader checks `pipeline_state` before processing each file — skips already-loaded files |
| First run | Full load | All files processed on first run; subsequent runs pick up only new files |

### Load Method by Layer

| Layer | Method | dbt Materialisation | Rationale |
|---|---|---|---|
| **Bronze** | Append only | Raw table (Python loader) | Non-volatile archive — records never updated or deleted |
| **Silver** | Upsert by natural key | `incremental` (merge) | Reflects corrections from source while preserving history |
| **Gold — Dimensions** | Full rebuild | `table` | Small tables, cheap to rebuild, always current |
| **Gold — Facts** | Incremental append | `incremental` | Large tables — only process new records each run |

### Pipeline Flow

```
[Source JSON files]
        │
        ▼
[Python Loaders]  ←── checks pipeline_state
        │
        ▼
[bronze.*]  ──── raw JSONB records + ingest_timestamp + source_file
        │
        ▼  dbt run
[silver.*]  ──── cleaned, typed, standardised
        │
        ▼  dbt run
[gold.*]    ──── star schema (facts + dimensions)
        │
        ▼
[Power BI / Looker Studio dashboards]
```

> *Architecture diagram image to be added — see `docs/etl_architecture.png`*

---

## 🛠️ Tech Stack

| Tool | Role | Why |
|---|---|---|
| **Python** | Data generation, loader scripts | Standard data engineering language |
| **PostgreSQL** | Data warehouse (structured like a data warehouse) | Free, handles analytical queries at SMB scale, connects to Power BI natively |
| **dbt** | Transformation layer — bronze → silver → gold | SQL-based transformations, version controlled, auto-documents lineage |
| **Apache Airflow** | Pipeline orchestration and scheduling | Visual DAGs, retry logic, schedule management |
| **Power BI** | Reporting and dashboards | Connects natively to PostgreSQL, accessible to non-technical users |
| **DuckDB** | Local exploration and transformation testing | Extremely fast for analytical queries during development |
| **Faker** | Synthetic data generation | Realistic names, addresses, and company details |

---

## 📊 Project Status

| Phase | Status | Notes |
|---|---|---|
| Business context document | ✅ Complete | SwiftRoute operating context — 22 sections |
| Industry knowledge base | ✅ Complete | Logistics guide — 84 pages, 30 chapters |
| Source system analysis | ✅ Complete | All 6 systems documented with quirks |
| Conceptual ERD | ✅ Complete | 11 entities, 4 groups, relationships mapped |
| Logical ERD | ✅ Complete | Star schema with fact + dimension tables |
| Physical ERD | ✅ Complete | Full column definitions, PKs, FKs, data types |
| Synthetic data generation | ✅ Complete | 6 generators, ~86K+ records across 6 systems |
| Bronze schema (PostgreSQL) | ✅ Complete | `schema.sql` defines all bronze tables |
| Loader scripts | 🔄 In Progress | Python scripts loading JSON → bronze |
| Silver dbt models | ⏳ Pending | |
| Gold dbt models | ⏳ Pending | |
| Airflow DAG | ⏳ Pending | |
| Dashboards | ⏳ Pending | |

---

## 🚀 How to Run

### Prerequisites

- Python 3.11+
- PostgreSQL 16
- dbt-core with dbt-postgres adapter
- Apache Airflow

### 1. Clone the repository

```bash
git clone https://github.com/your-username/swiftroute_ods.git
cd swiftroute_ods
```

### 2. Install Python dependencies

```bash
pip install -r requirements.txt
```

### 3. Configure environment variables

Copy `.env.example` to `.env` and fill in your PostgreSQL credentials:

```
DB_HOST=localhost
DB_PORT=5432
DB_NAME=swiftroute_ods
DB_USER=postgres
DB_PASSWORD=your_password_here
```

### 4. Generate source data

```bash
python generators/generate_onfleet.py
python generators/generate_linnworks.py
python generators/generate_quickbooks.py
python generators/generate_gusto.py
python generators/generate_samsara.py
python generators/generate_salesforce.py
```

### 5. Create the database schema

```bash
psql -U postgres -d swiftroute_ods -f db/schema.sql
```

### 6. Run the loaders

```bash
python loaders/load_onfleet.py
python loaders/load_linnworks.py
python loaders/load_quickbooks.py
python loaders/load_gusto.py
python loaders/load_samsara.py
python loaders/load_salesforce.py
```

### 7. Run dbt transformations

```bash
cd dbt_project
dbt run
dbt test
```

---

## 📝 Notes

- `source_data/` is git-ignored — run the generators locally to recreate it
- `~/.dbt/profiles.yml` lives outside the project folder (standard dbt behaviour) — see dbt documentation for setup
- All monetary values from Gusto are strings in the raw data and must be cast to float in silver models
- Onfleet timestamps are in milliseconds — divide by 1000 before converting to datetime
- Samsara coordinates use named keys `{latitude, longitude}` — Onfleet uses positional `[longitude, latitude]`

---

*This project is a simulation built for learning purposes. SwiftRoute Logistics is a fictional company. All data is synthetically generated.*