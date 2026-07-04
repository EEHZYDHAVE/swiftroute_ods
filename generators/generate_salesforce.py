"""
generators/generate_salesforce.py

Generates synthetic Salesforce REST API responses for SwiftRoute Logistics.
Imports CLIENTS and ZONES from shared_ids.py (written by
generate_shared_ids.py, which must run first) — shared_ids.py is
authoritative for client identity, tier, city, is_fulfillment,
discount_rate, and payment_terms (the exact-2-net-60 fact must be the
SAME two clients here as in QuickBooks — if Salesforce invented its own
independent net-60 selection, the CRM and the accounting system would
disagree about who's on extended terms, which is exactly the kind of
cross-system contradiction this whole rebuild exists to eliminate).

Salesforce-only fields (revenue, industry, billing address, CRM
staleness, contract volume) are generated locally since they aren't
shared business facts.

Mirrors the real Salesforce REST API JSON structure from three objects:
  GET /services/data/v58.0/query?q=SELECT...FROM Account
  GET /services/data/v58.0/query?q=SELECT...FROM Contract
  GET /services/data/v58.0/query?q=SELECT...FROM Opportunity

Quirks intentionally reproduced:
  1. Rate card lives in a custom object (Contract_Rate__c) separate from Contract
  2. Account.BillingAddress is a compound field — not a simple string
  3. Some Contracts have no linked Account (orphaned during a data migration)
  4. CRM data is stale — LastActivityDate lags reality by weeks or months
  5. Opportunity CloseDate is in the past for won deals — not the renewal date
  6. Custom fields use __c suffix

Output:
  source_data/raw/salesforce/accounts/page_{NNNN}.json
  source_data/raw/salesforce/contracts/page_{NNNN}.json
  source_data/raw/salesforce/contract_rates/page_{NNNN}.json
  source_data/raw/salesforce/opportunities/page_{NNNN}.json

Period: accounts and contracts as of June 2025 (point-in-time snapshot)
"""

import json
import os
import random
import string
from datetime import datetime, timedelta, timezone
from faker import Faker

import shared_ids

SEED = 42
random.seed(SEED)
fake = Faker()
Faker.seed(SEED)

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTPUT_BASE  = os.path.join(PROJECT_ROOT, "source_data", "raw", "salesforce")

SF_INSTANCE = "https://swiftroute.my.salesforce.com"
API_VERSION = "v58.0"
PAGE_SIZE = 200

AS_OF = datetime(2025, 6, 30, tzinfo=timezone.utc)

BASE_RATES = {
    "same_day":          (8.50,  32.00),
    "next_day":          (6.50,  24.00),
    "scheduled":         (12.00, 28.00),
    "distribution_run":  (85.00, 280.00),
    "fulfillment_pick":  (1.80,  4.50),
    "storage":           (28.00, 95.00),
    "returns":           (5.00,  18.00),
}

REVENUE_RANGE_BY_TIER = {
    "platinum": (180000, 480000),
    "gold":     (45000,  180000),
    "standard": (5000,   45000),
}


def zone_ids_by_city():
    zones = {}
    for z in shared_ids.ZONES:
        zones.setdefault(z["city"], []).append(z["zone_id"])
    return zones

ZONE_IDS = zone_ids_by_city()


def sf_id(prefix="001"):
    chars = string.ascii_letters + string.digits
    body = "".join(random.choices(chars, k=15))
    return f"{prefix}{body}"

def sf_datetime(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%S.000+0000")

def sf_date(dt):
    return dt.strftime("%Y-%m-%d")

def sf_attrs(obj_type, record_id):
    return {"type": obj_type, "url": f"/services/data/{API_VERSION}/sobjects/{obj_type}/{record_id}"}


# ══════════════════════════════════════════════════════════════════════════
#  ACCOUNT BUILDER — sourced from shared_ids.CLIENTS
# ══════════════════════════════════════════════════════════════════════════

def build_accounts():
    """
    94 Salesforce Account records, one per shared_ids client.

    Identity, tier, city, is_fulfillment, discount_rate, and
    payment_terms all come from shared_ids — not re-invented here.
    QUIRK 2: BillingAddress is a compound field.
    QUIRK 4: LastActivityDate lags reality (CRM only updated at QBRs).
    QUIRK 6: custom fields end in __c.
    """
    random.seed(800)
    Faker.seed(800)

    accounts = []
    for c in shared_ids.CLIENTS:
        acct_id = sf_id("001")
        owner_id = sf_id("005")
        tier = c["tier"]

        lag_days = {
            "platinum": random.randint(1, 20),
            "gold":     random.randint(5, 45),
            "standard": random.randint(14, 90),
        }[tier]
        last_activity = AS_OF - timedelta(days=lag_days)
        created_date = AS_OF - timedelta(days=random.randint(90, 1800))
        annual_rev = random.randint(*REVENUE_RANGE_BY_TIER[tier])

        accounts.append({
            "attributes": sf_attrs("Account", acct_id),
            "Id":         acct_id,
            "Name":       c["name"],
            "Type":       "Customer",
            "Industry":   random.choice([
                "Retail", "E-Commerce", "Healthcare", "Manufacturing",
                "Food & Beverage", "Technology", "Professional Services",
            ]),
            "Phone":   fake.phone_number(),
            "Website": f"https://www.{fake.domain_name()}",

            "BillingAddress": {          # QUIRK 2: compound, not a string
                "street":      fake.street_address(),
                "city":        fake.city(),
                "state":       fake.state(),
                "postalCode":  fake.postcode(),
                "country":     "United States",
                "stateCode":   "CO",
                "countryCode": "US",
            },

            "AnnualRevenue": annual_rev,
            "NumberOfEmployees": random.randint(3, 850),

            "LastActivityDate": sf_date(last_activity),   # QUIRK 4
            "LastModifiedDate": sf_datetime(last_activity),
            "CreatedDate":      sf_datetime(created_date),

            "OwnerId": owner_id,
            "Owner": {
                "attributes": sf_attrs("User", owner_id),
                "Name": fake.name(),
                "Email": fake.email(),
            },

            "SwiftRoute_Client_ID__c":  c["internal_id"],
            "Account_Tier__c":          tier,
            "Primary_City__c":          c["city"],
            "Contract_Type__c":         c["contract_type"],
            "Contracted_Monthly_Volume__c": random.randint(30, 1800) if tier != "standard" else random.randint(10, 200),
            "Discount_Rate__c":         c["discount_rate"],
            "Is_Fulfillment_Client__c": c["is_fulfillment"],
            "Net_Payment_Terms__c":     c["payment_terms"],   # from shared_ids — same 2 net-60 clients as QuickBooks
        })

    random.seed(SEED)
    Faker.seed(SEED)
    return accounts


# ══════════════════════════════════════════════════════════════════════════
#  CONTRACT BUILDER
# ══════════════════════════════════════════════════════════════════════════

def build_contracts(accounts):
    """One Contract per Account. QUIRK 3: 3 contracts have no AccountId."""
    random.seed(810)
    contracts = []
    orphan_indices = random.sample(range(20, 94), 3)

    for idx, acct in enumerate(accounts):
        contract_id = sf_id("800")
        start = AS_OF - timedelta(days=random.randint(60, 700))
        end = start + timedelta(days=365)
        signed = start - timedelta(days=random.randint(5, 30))
        tier = acct["Account_Tier__c"]
        contract_type = acct["Contract_Type__c"]

        contracts.append({
            "attributes": sf_attrs("Contract", contract_id),
            "Id": contract_id,
            "AccountId": None if idx in orphan_indices else acct["Id"],
            "Account": {
                "attributes": sf_attrs("Account", acct["Id"]),
                "Name": acct["Name"],
                "SwiftRoute_Client_ID__c": acct["SwiftRoute_Client_ID__c"],
            } if idx not in orphan_indices else None,
            "Status": random.choices(
                ["Activated", "Activated", "Activated", "Draft", "Expired"],
                weights=[0.80, 0.05, 0.05, 0.05, 0.05]
            )[0],
            "StartDate": sf_date(start),
            "EndDate": sf_date(end),
            "ContractTerm": 12,
            "SignedDate__c": sf_date(signed),
            "Contract_Type__c": contract_type,
            "Committed_Monthly_Volume__c": acct["Contracted_Monthly_Volume__c"],
            "Discount_Rate__c": acct["Discount_Rate__c"],
            "Net_Payment_Terms__c": acct["Net_Payment_Terms__c"],
            "Auto_Renewal__c": random.random() > 0.35,
            "Termination_Notice_Days__c": 60,
            "Primary_City__c": acct["Primary_City__c"],
            "Account_Tier__c": tier,
            "_rate_note": (
                "QUIRK 1: per-service, per-zone rates are stored in "
                "Contract_Rate__c records linked to this contract. "
                "Two separate API calls needed for a complete picture."
            ),
            "CreatedDate": sf_datetime(signed),
            "LastModifiedDate": sf_datetime(signed + timedelta(days=random.randint(1, 30))),
            "OwnerId": acct["OwnerId"],
        })

    random.seed(SEED)
    return contracts


# ══════════════════════════════════════════════════════════════════════════
#  CONTRACT RATE BUILDER
# ══════════════════════════════════════════════════════════════════════════

def build_contract_rates(accounts, contracts):
    """Contract_Rate__c — the actual rate card, a separate object.
    QUIRK 1: requires a completely separate API query."""
    random.seed(820)
    rates = []
    contract_map = {c["AccountId"]: c for c in contracts if c["AccountId"]}

    for acct in accounts:
        contract = contract_map.get(acct["Id"])
        if not contract:
            continue

        city = acct["Primary_City__c"]
        discount = acct["Discount_Rate__c"]
        zones = ZONE_IDS.get(city, ZONE_IDS["denver"])

        is_ff = acct["Is_Fulfillment_Client__c"]
        if is_ff:
            svc_types = ["fulfillment_pick", "storage", "returns"]
        else:
            tier = acct["Account_Tier__c"]
            svc_types = ["next_day"]
            if tier in ("platinum", "gold") or random.random() > 0.5:
                svc_types.append("same_day")
            if random.random() > 0.7:
                svc_types.append("returns")
            if tier == "platinum" and random.random() > 0.5:
                svc_types.append("distribution_run")

        for svc in svc_types:
            lo, hi = BASE_RATES[svc]
            base_rate = round(random.uniform(lo, hi), 2)

            if svc in ("fulfillment_pick", "storage"):
                rate_id = sf_id("a0B")
                rates.append({
                    "attributes": sf_attrs("Contract_Rate__c", rate_id),
                    "Id": rate_id,
                    "Contract__c": contract["Id"],
                    "Account__c": acct["Id"],
                    "SwiftRoute_Client_ID__c": acct["SwiftRoute_Client_ID__c"],
                    "Service_Type__c": svc,
                    "Zone_ID__c": None,
                    "Zone_Name__c": None,
                    "Base_Rate__c": base_rate,
                    "Discount_Rate__c": discount,
                    "Net_Rate__c": round(base_rate * (1 - discount), 2),
                    "Unit__c": "per_unit" if svc == "fulfillment_pick" else "per_pallet_per_month",
                    "Effective_Date__c": contract["StartDate"],
                    "CreatedDate": contract["CreatedDate"],
                })
            else:
                for zone_id in zones:
                    rate_id = sf_id("a0B")
                    zone_surcharge = (
                        1.25 if zone_id in ("zone_den_9", "zone_abq_3")
                        else 1.10 if zone_id in ("zone_den_4", "zone_abq_4")
                        else 1.00
                    )
                    zone_rate = round(base_rate * zone_surcharge, 2)
                    net_rate = round(zone_rate * (1 - discount), 2)
                    rates.append({
                        "attributes": sf_attrs("Contract_Rate__c", rate_id),
                        "Id": rate_id,
                        "Contract__c": contract["Id"],
                        "Account__c": acct["Id"],
                        "SwiftRoute_Client_ID__c": acct["SwiftRoute_Client_ID__c"],
                        "Service_Type__c": svc,
                        "Zone_ID__c": zone_id,
                        "Zone_Name__c": zone_id.replace("_", " ").title(),
                        "Base_Rate__c": zone_rate,
                        "Discount_Rate__c": discount,
                        "Net_Rate__c": net_rate,
                        "Unit__c": "per_delivery",
                        "Effective_Date__c": contract["StartDate"],
                        "CreatedDate": contract["CreatedDate"],
                    })

    random.seed(SEED)
    return rates


# ══════════════════════════════════════════════════════════════════════════
#  OPPORTUNITY BUILDER
# ══════════════════════════════════════════════════════════════════════════

def build_opportunities(accounts):
    """QUIRK 5: CloseDate on won deals is the signing date, not renewal date."""
    random.seed(830)
    opps = []
    stages = ["Prospecting","Qualification","Proposal/Price Quote","Negotiation","Closed Won","Closed Lost"]

    for acct in accounts:
        if random.random() < 0.35:
            continue

        opp_id = sf_id("006")
        stage = random.choices(stages, weights=[0.15, 0.15, 0.20, 0.20, 0.20, 0.10])[0]
        close_dt = (AS_OF - timedelta(days=random.randint(1, 180))
                    if stage in ("Closed Won", "Closed Lost")
                    else AS_OF + timedelta(days=random.randint(15, 120)))

        opps.append({
            "attributes": sf_attrs("Opportunity", opp_id),
            "Id": opp_id,
            "AccountId": acct["Id"],
            "Account": {
                "attributes": sf_attrs("Account", acct["Id"]),
                "Name": acct["Name"],
                "SwiftRoute_Client_ID__c": acct["SwiftRoute_Client_ID__c"],
            },
            "Name": f"{acct['Name']} — Contract Renewal 2025",
            "StageName": stage,
            "Amount": round(random.randint(5000, 480000) * random.uniform(0.8, 1.2), 2),
            "CloseDate": sf_date(close_dt),
            "Probability": {
                "Prospecting": 10, "Qualification": 25,
                "Proposal/Price Quote": 50, "Negotiation": 75,
                "Closed Won": 100, "Closed Lost": 0,
            }[stage],
            "Type": "Renewal",
            "LeadSource": random.choice(["Existing Customer", "Referral", "Web", "Cold Call"]),
            "OwnerId": acct["OwnerId"],
            "CreatedDate": sf_datetime(AS_OF - timedelta(days=random.randint(10, 200))),
            "LastActivityDate": sf_date(AS_OF - timedelta(days=random.randint(1, 30))),
            "Contract_Type__c": acct["Contract_Type__c"],
            "Primary_City__c": acct["Primary_City__c"],
            "Account_Tier__c": acct["Account_Tier__c"],
        })

    random.seed(SEED)
    return opps


# ══════════════════════════════════════════════════════════════════════════
#  WRITER
# ══════════════════════════════════════════════════════════════════════════

def write_sf_pages(records, folder, object_type):
    os.makedirs(folder, exist_ok=True)
    pages = [records[i:i+PAGE_SIZE] for i in range(0, len(records), PAGE_SIZE)]
    total_pages = len(pages)

    for idx, page in enumerate(pages, start=1):
        is_last = idx == total_pages
        payload = {
            "totalSize": len(records),
            "done": is_last,
            "nextRecordsUrl": None if is_last else f"/services/data/{API_VERSION}/query/{object_type}-{idx+1}",
            "records": page,
        }
        with open(os.path.join(folder, f"page_{str(idx).zfill(4)}.json"), "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2, ensure_ascii=False)

    return total_pages


# ══════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════

def main():
    print("SwiftRoute — Salesforce raw data generator")
    print("=" * 45)

    accounts = build_accounts()
    contracts = build_contracts(accounts)
    rates = build_contract_rates(accounts, contracts)
    opps = build_opportunities(accounts)

    orphaned_contracts = [c for c in contracts if c["AccountId"] is None]
    net60_accounts = [a for a in accounts if a["Net_Payment_Terms__c"] == 60]
    custom_fields_example = [k for k in accounts[0].keys() if k.endswith("__c")]

    a_pages = write_sf_pages(accounts, os.path.join(OUTPUT_BASE, "accounts"), "Account")
    c_pages = write_sf_pages(contracts, os.path.join(OUTPUT_BASE, "contracts"), "Contract")
    r_pages = write_sf_pages(rates, os.path.join(OUTPUT_BASE, "contract_rates"), "Contract_Rate__c")
    o_pages = write_sf_pages(opps, os.path.join(OUTPUT_BASE, "opportunities"), "Opportunity")

    print(f"Accounts          : {len(accounts):,}  ({a_pages} page)")
    print(f"Contracts         : {len(contracts):,}  ({c_pages} page)")
    print(f"  Orphaned        : {len(orphaned_contracts):,}  ← QUIRK 3")
    print(f"Contract rates    : {len(rates):,}  ({r_pages} pages)  ← QUIRK 1 (separate object)")
    print(f"Opportunities     : {len(opps):,}  ({o_pages} page)")
    print()
    print("Quirk verification:")
    print(f"  Custom fields   : {custom_fields_example}  ← QUIRK 6")
    print(f"  Orphaned ctrs   : {len(orphaned_contracts)} contracts with null AccountId")
    print(f"  Net-60 accounts : {len(net60_accounts)}  (from shared_ids — same clients as QuickBooks)")
    print(f"  Compound addr   : accounts[0].BillingAddress is object not string  ← QUIRK 2")
    print(f"  Rates are sep.  : {len(rates)} rate records in separate contract_rates/  ← QUIRK 1")
    print(f"\nOutput: {OUTPUT_BASE}")


if __name__ == "__main__":
    main()