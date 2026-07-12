"""
simulators/simulate_salesforce.py

Incremental Salesforce simulator. accounts/, contracts/, and
contract_rates/ are NEVER touched — they only change for a new client
or contract renewal, both out of scope. The only thing that moves here
is opportunity stage progression.

Rather than rewriting the existing opportunities file (which would
violate "never modify existing files"), this writes a NEW page
containing only the opportunities that changed stage this run — a
delta capture. A silver-layer model would resolve current state by
taking the latest record per Opportunity Id, which is how a real
CDC/polling pipeline naturally works anyway.
"""

import os
import sys
import glob
import json
import random
import argparse
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "generators"))

import _common
import generate_salesforce as sf

SEED = 42

STAGE_ORDER = ["Prospecting", "Qualification", "Proposal/Price Quote", "Negotiation"]
PROBABILITY_BY_STAGE = {
    "Prospecting": 10, "Qualification": 25, "Proposal/Price Quote": 50,
    "Negotiation": 75, "Closed Won": 100, "Closed Lost": 0,
}
ADVANCE_CHANCE_PER_RUN = 0.15   # per open opportunity, per ~week


def load_latest_opportunity_states():
    """Opportunities may have been updated across several prior
    incremental runs (multiple pages). This resolves the CURRENT state
    of each Opportunity Id by taking the record from the LATEST page
    file that mentions it (later files = more recent runs)."""
    latest = {}
    for f in sorted(glob.glob(_common.system_path("salesforce", "opportunities", "page_*.json"))):
        with open(f) as fh:
            payload = json.load(fh)
        for opp in payload["records"]:
            latest[opp["Id"]] = opp   # later files overwrite earlier ones for the same Id
    return latest


def run(start_date, end_date):
    print(f"[salesforce] simulating {start_date} -> {end_date}")
    random.seed(SEED)

    current_state = load_latest_opportunity_states()
    open_opps = [o for o in current_state.values() if o["StageName"] not in ("Closed Won", "Closed Lost")]

    updated = []
    as_of = datetime(end_date.year, end_date.month, end_date.day, tzinfo=timezone.utc)

    for opp in open_opps:
        if random.random() >= ADVANCE_CHANCE_PER_RUN:
            continue

        stage = opp["StageName"]
        new_opp = dict(opp)   # copy — never mutate the record we read

        if stage == "Negotiation":
            new_stage = "Closed Won" if random.random() < 0.8 else "Closed Lost"
            new_opp["CloseDate"] = sf.sf_date(as_of)
        elif stage in STAGE_ORDER:
            idx = STAGE_ORDER.index(stage)
            new_stage = STAGE_ORDER[idx + 1] if idx + 1 < len(STAGE_ORDER) else "Negotiation"
        else:
            continue

        new_opp["StageName"] = new_stage
        new_opp["Probability"] = PROBABILITY_BY_STAGE[new_stage]
        new_opp["LastActivityDate"] = sf.sf_date(as_of)
        updated.append(new_opp)

    folder = _common.system_path("salesforce", "opportunities")
    start_page = _common.next_page_number(folder)
    if updated:
        payload = {
            "totalSize": len(updated),
            "done": True,
            "nextRecordsUrl": None,
            "records": updated,
        }
        _common.write_json(os.path.join(folder, f"page_{str(start_page).zfill(4)}.json"), payload)

    print(f"[salesforce] done. {len(updated)} opportunity stage update(s) written. "
          f"accounts/contracts/contract_rates untouched.")
    return len(updated)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--start-date", required=True)
    parser.add_argument("--end-date", required=True)
    args = parser.parse_args()
    s = datetime.strptime(args.start_date, "%Y-%m-%d").date()
    e = datetime.strptime(args.end_date, "%Y-%m-%d").date()
    run(s, e)
