"""
DAG:         swiftroute_pipeline
Description: Orchestrates the full SwiftRoute ODS pipeline.
             Runs in this order:
             1. Simulate new source data (optional, controlled by Variable)
             2. Load all six source systems into bronze
             3. Run dbt silver models
             4. Run dbt gold_operations models
             5. Run dbt tests on gold layer

Schedule:    Weekly (every Monday at 06:00 UTC)
             Adjust SCHEDULE_INTERVAL to change frequency.

Owner:       swiftroute_ods
"""

from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.python import PythonOperator
from airflow.models import Variable

# ============================================================
# DEFAULT ARGS
# Applied to all tasks unless overridden at task level.
# ============================================================
DEFAULT_ARGS = {
    "owner": "swiftroute_ods",
    "depends_on_past": False,
    "email_on_failure": False,
    "email_on_retry": False,
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
}

# ============================================================
# PROJECT PATHS
# Adjust PROJECT_ROOT if the project is mounted differently
# inside the Airflow container.
# ============================================================
PROJECT_ROOT = "/opt/airflow/swiftroute_ods"
DBT_PROJECT_DIR = f"{PROJECT_ROOT}/dbt_project"
DBT_PROFILES_DIR = f"{DBT_PROJECT_DIR}"

# ============================================================
# SCHEDULE
# Default: every Monday at 06:00 UTC.
# Change to "0 6 * * *" for daily runs.
# ============================================================
SCHEDULE_INTERVAL = "0 6 * * 1"

# ============================================================
# DAG DEFINITION
# ============================================================
with DAG(
    dag_id="swiftroute_pipeline",
    description="SwiftRoute ODS: simulate, load, transform, test",
    default_args=DEFAULT_ARGS,
    start_date=datetime(2025, 7, 1),
    schedule_interval=SCHEDULE_INTERVAL,
    catchup=False,
    max_active_runs=1,
    tags=["swiftroute", "ods", "pipeline"],
) as dag:

    # ============================================================
    # TASK 1: SIMULATE NEW SOURCE DATA
    # Runs the incremental simulator to produce new JSON files
    # for the next 7-day window. Pipeline-safe: simulator
    # auto-detects where the last run left off.
    # ============================================================
    simulate_new_data = BashOperator(
        task_id="simulate_new_data",
        bash_command=f"cd {PROJECT_ROOT} && python simulators/run_simulation.py",
        doc_md="""
        Runs the incremental data simulator to produce new JSON
        files for all six source systems for the next 7-day window.
        The simulator auto-detects the last simulated date and
        advances from there. No arguments needed.
        """,
    )

    # ============================================================
    # TASK GROUP 2: LOAD BRONZE
    # One task per source system. Onfleet must complete before
    # Samsara starts (Samsara trips derived from Onfleet tasks).
    # All others run in parallel after Onfleet completes.
    # ============================================================
    load_onfleet = BashOperator(
        task_id="load_onfleet",
        bash_command=f"cd {PROJECT_ROOT} && python loaders/load_onfleet.py",
        doc_md="Loads new Onfleet delivery and worker files into bronze.",
    )

    load_samsara = BashOperator(
        task_id="load_samsara",
        bash_command=f"cd {PROJECT_ROOT} && python loaders/load_samsara.py",
        doc_md="Loads new Samsara trip and vehicle files into bronze. Runs after Onfleet.",
    )

    load_gusto = BashOperator(
        task_id="load_gusto",
        bash_command=f"cd {PROJECT_ROOT} && python loaders/load_gusto.py",
        doc_md="Loads new Gusto payroll files into bronze.",
    )

    load_linnworks = BashOperator(
        task_id="load_linnworks",
        bash_command=f"cd {PROJECT_ROOT} && python loaders/load_linnworks.py",
        doc_md="Loads new Linnworks order and stock transaction files into bronze.",
    )

    load_quickbooks = BashOperator(
        task_id="load_quickbooks",
        bash_command=f"cd {PROJECT_ROOT} && python loaders/load_quickbooks.py",
        doc_md="Loads new QuickBooks invoice, payment, and expense files into bronze.",
    )

    load_salesforce = BashOperator(
        task_id="load_salesforce",
        bash_command=f"cd {PROJECT_ROOT} && python loaders/load_salesforce.py",
        doc_md="Loads new Salesforce opportunity files into bronze.",
    )

    # ============================================================
    # TASK 3: DBT SILVER
    # Runs all 18 silver models. dbt handles dependency order
    # internally via the DAG defined by {{ ref() }} calls.
    # ============================================================
    dbt_run_silver = BashOperator(
        task_id="dbt_run_silver",
        bash_command=(
            f"cd {DBT_PROJECT_DIR} && "
            f"dbt run --select silver.* "
            f"--profiles-dir {DBT_PROFILES_DIR}"
        ),
        doc_md="Runs all 18 silver dbt models incrementally.",
    )

    # ============================================================
    # TASK 4: DBT GOLD
    # Runs all 12 gold_operations models. dbt handles order.
    # ============================================================
    dbt_run_gold = BashOperator(
        task_id="dbt_run_gold",
        bash_command=(
            f"cd {DBT_PROJECT_DIR} && "
            f"dbt run --select gold_operations.* "
            f"--profiles-dir {DBT_PROFILES_DIR}"
        ),
        doc_md="Runs all 12 gold_operations dbt models.",
    )

    # ============================================================
    # TASK 5: DBT TEST
    # Runs all 42 data quality tests on the gold layer.
    # Pipeline fails here if any PK, FK, or not_null test fails.
    # ============================================================
    dbt_test_gold = BashOperator(
        task_id="dbt_test_gold",
        bash_command=(
            f"cd {DBT_PROJECT_DIR} && "
            f"dbt test --select gold_operations.* "
            f"--profiles-dir {DBT_PROFILES_DIR}"
        ),
        doc_md="Runs all 42 dbt data quality tests on the gold layer.",
    )

    # ============================================================
    # DEPENDENCY CHAIN
    # Defines the execution order of the pipeline.
    #
    # simulate_new_data
    #     --> load_onfleet
    #             --> load_samsara  (must wait for onfleet)
    #             --> load_gusto    (parallel after onfleet)
    #             --> load_linnworks
    #             --> load_quickbooks
    #             --> load_salesforce
    #                     --> dbt_run_silver
    #                             --> dbt_run_gold
    #                                     --> dbt_test_gold
    # ============================================================

    # step 1 to step 2a
    simulate_new_data >> load_onfleet

    # onfleet gates samsara
    load_onfleet >> load_samsara

    # remaining loaders run in parallel after onfleet
    load_onfleet >> [
        load_gusto,
        load_linnworks,
        load_quickbooks,
        load_salesforce
    ]

    # all loaders must complete before silver runs
    [
        load_samsara,
        load_gusto,
        load_linnworks,
        load_quickbooks,
        load_salesforce
    ] >> dbt_run_silver

    # silver gates gold
    dbt_run_silver >> dbt_run_gold

    # gold gates tests
    dbt_run_gold >> dbt_test_gold