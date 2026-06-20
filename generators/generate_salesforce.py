"""
generators/generate_salesforce.py

Generates synthetic Salesforce REST API responses for SwiftRoute Logistics.
Mirrors the real Salesforce REST API JSON structure from three objects:

  GET /services/data/v58.0/query?q=SELECT...FROM Account
  GET /services/data/v58.0/query?q=SELECT...FROM Contract
  GET /services/data/v58.0/query?q=SELECT...FROM Opportunity

Salesforce API characteristics:
  - Salesforce Object Query Language (SOQL) — SQL-like but Salesforce-specific
  - Pagination via nextRecordsUrl (a URL path, not a cursor token)
  - Response envelope: {"totalSize": N, "done": bool, "records": [...]}
  - Every record has "attributes": {"type": "Account", "url": "/services/..."}
  - IDs are 18-character alphanumeric strings (case-sensitive)
  - Datetime fields: "2025-01-15T09:32:00.000+0000"
  - Date fields: "2025-01-15"
  - Null values are literally null (not "" like some systems)
  - Related objects are nested: Account.Owner.Name

Quirks intentionally reproduced:
  1. Rate card lives in a custom object (Contract_Rate__c) separate from Contract
     — requires two separate API calls to assemble a complete contract picture
  2. Account.BillingAddress is a compound field — not a simple string
  3. Some Contracts have no linked Account (orphaned during a data migration)
  4. CRM data is stale — LastActivityDate lags reality by weeks or months
  5. Opportunity CloseDate is in the past for won deals — not the renewal date
  6. Custom fields use __c suffix — easy to mistake for standard fields

Output:
  data/raw/salesforce/accounts/page_{NNNN}.json
  data/raw/salesforce/contracts/page_{NNNN}.json
  data/raw/salesforce/contract_rates/page_{NNNN}.json
  data/raw/salesforce/opportunities/page_{NNNN}.json

Period: accounts and contracts as of June 2025 (point-in-time snapshot)
"""

import json
import os
import random
import string
from datetime import datetime, timedelta, timezone
from faker import Faker

# ── Reproducibility ────────────────────────────────────────────────────────────
SEED = 42
random.seed(SEED)
fake = Faker()
Faker.seed(SEED)

# ── Paths ──────────────────────────────────────────────────────────────────────
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTPUT_BASE  = os.path.join(PROJECT_ROOT, "data", "raw", "salesforce")

# ── Salesforce constants ───────────────────────────────────────────────────────
SF_INSTANCE  = "https://swiftroute.my.salesforce.com"
API_VERSION  = "v58.0"
PAGE_SIZE    = 200   # Salesforce default

# ── Reference date ─────────────────────────────────────────────────────────────
AS_OF = datetime(2025, 6, 30, tzinfo=timezone.utc)

# ── Service types and zones (must match Onfleet reference data) ────────────────
SERVICE_TYPES = ["same_day", "next_day", "scheduled", "distribution_run",
                 "fulfillment_pick", "storage", "returns"]

ZONE_IDS = {
    "denver":         [f"zone_den_{i}" for i in range(1, 10)],
    "salt_lake_city": [f"zone_slc_{i}" for i in range(1, 5)],
    "albuquerque":    [f"zone_abq_{i}" for i in range(1, 5)],
}

# ── Rate ranges by service type ────────────────────────────────────────────────
BASE_RATES = {
    "same_day":          (8.50,  32.00),
    "next_day":          (6.50,  24.00),
    "scheduled":         (12.00, 28.00),
    "distribution_run":  (85.00, 280.00),
    "fulfillment_pick":  (1.80,  4.50),
    "storage":           (28.00, 95.00),
    "returns":           (5.00,  18.00),
}

# ── Account tier specs ─────────────────────────────────────────────────────────
TIER_SPECS = [
    # (tier,      sf_type,  count, annual_rev_range,   discount_pct)
    ("platinum",  "Customer", 9,  (180000, 480000),   (0.18, 0.26)),
    ("gold",      "Customer", 28, (45000,  180000),   (0.10, 0.18)),
    ("standard",  "Customer", 57, (5000,   45000),    (0.00, 0.10)),
]

# ══════════════════════════════════════════════════════════════════════════════
#  HELPERS
# ══════════════════════════════════════════════════════════════════════════════

def sf_id(prefix="001"):
    """18-character Salesforce ID — prefix identifies the object type."""
    chars = string.ascii_letters + string.digits
    body  = "".join(random.choices(chars, k=15))
    return f"{prefix}{body}"

def sf_datetime(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%S.000+0000")

def sf_date(dt):
    return dt.strftime("%Y-%m-%d")

def sf_attrs(obj_type, record_id):
    """Every Salesforce record has an attributes block."""
    return {
        "type": obj_type,
        "url":  f"/services/data/{API_VERSION}/sobjects/{obj_type}/{record_id}",
    }

# ══════════════════════════════════════════════════════════════════════════════
#  ACCOUNT BUILDER  (94 client accounts)
# ══════════════════════════════════════════════════════════════════════════════

def build_accounts():
    """
    94 Salesforce Account records — one per SwiftRoute client.

    QUIRK 2: BillingAddress is a compound field containing sub-fields.
    Naive code that tries to read Account["BillingAddress"] as a string
    will fail — it is an object with Street, City, State, PostalCode, Country.

    QUIRK 4: LastActivityDate significantly lags reality for most accounts.
    The CRM is only updated during formal QBRs or contract events.
    Day-to-day client communication happens over email/phone and is not logged.

    QUIRK 6: Custom fields end in __c — SwiftRoute_Client_ID__c,
    Contract_Type__c, Primary_City__c. These are indistinguishable from
    standard fields at a glance but behave differently in SOQL.
    """
    random.seed(800)
    Faker.seed(800)

    accounts = []
    acct_idx = 1

    for tier, sf_type, count, rev_range, disc_range in TIER_SPECS:
        for i in range(count):
            acct_id   = sf_id("001")
            owner_id  = sf_id("005")
            city_key  = random.choices(
                ["denver", "salt_lake_city", "albuquerque"],
                weights=[0.72, 0.18, 0.10]
            )[0]

            # QUIRK 4: last activity date lags — up to 90 days for standard tier
            lag_days = {
                "platinum": random.randint(1,  20),
                "gold":     random.randint(5,  45),
                "standard": random.randint(14, 90),
            }[tier]
            last_activity = AS_OF - timedelta(days=lag_days)

            created_date = AS_OF - timedelta(days=random.randint(90, 1800))

            annual_rev   = random.randint(*rev_range)
            discount     = round(random.uniform(*disc_range), 3)

            accounts.append({
                "attributes": sf_attrs("Account", acct_id),
                "Id":          acct_id,
                "Name":        fake.company(),
                "Type":        sf_type,
                "Industry":    random.choice([
                    "Retail", "E-Commerce", "Healthcare", "Manufacturing",
                    "Food & Beverage", "Technology", "Professional Services",
                ]),
                "Phone":        fake.phone_number(),
                "Website":      f"https://www.{fake.domain_name()}",

                # QUIRK 2: BillingAddress is a compound object, not a string
                "BillingAddress": {
                    "street":     fake.street_address(),
                    "city":       fake.city(),
                    "state":      fake.state(),
                    "postalCode": fake.postcode(),
                    "country":    "United States",
                    "stateCode":  "CO",
                    "countryCode":"US",
                },

                "AnnualRevenue": annual_rev,
                "NumberOfEmployees": random.randint(3, 850),

                # QUIRK 4: stale CRM data
                "LastActivityDate":  sf_date(last_activity),
                "LastModifiedDate":  sf_datetime(last_activity),
                "CreatedDate":       sf_datetime(created_date),

                "OwnerId":  owner_id,
                "Owner": {
                    "attributes": sf_attrs("User", owner_id),
                    "Name": fake.name(),
                    "Email": fake.email(),
                },

                # QUIRK 6: custom fields with __c suffix
                "SwiftRoute_Client_ID__c":  f"client_{str(acct_idx).zfill(3)}",
                "Account_Tier__c":          tier,
                "Primary_City__c":          city_key,
                "Contract_Type__c":         random.choice([
                    "Variable Rate", "Fixed Monthly", "Pay As You Go",
                ]),
                "Contracted_Monthly_Volume__c": random.randint(30, 1800)
                                                if tier != "standard"
                                                else random.randint(10, 200),
                "Discount_Rate__c":         discount,
                "Is_Fulfillment_Client__c": acct_idx <= 11,
                "Net_Payment_Terms__c":     60 if random.random() < 0.022 else 30,
            })
            acct_idx += 1

    random.seed(SEED)
    Faker.seed(SEED)
    return accounts


# ══════════════════════════════════════════════════════════════════════════════
#  CONTRACT BUILDER
# ══════════════════════════════════════════════════════════════════════════════

def build_contracts(accounts):
    """
    One Contract per Account (94 total).
    QUIRK 3: 3 contracts have no AccountId — orphaned during migration.
    """
    random.seed(810)
    contracts = []

    # Pick 3 accounts whose contracts will be orphaned
    orphan_indices = random.sample(range(20, 94), 3)

    for idx, acct in enumerate(accounts):
        contract_id  = sf_id("800")
        start        = AS_OF - timedelta(days=random.randint(60, 700))
        end          = start + timedelta(days=365)
        signed       = start - timedelta(days=random.randint(5, 30))

        tier = acct["Account_Tier__c"]
        contract_type = acct["Contract_Type__c"]

        contracts.append({
            "attributes":    sf_attrs("Contract", contract_id),
            "Id":            contract_id,
            # QUIRK 3: some contracts have null AccountId
            "AccountId":     None if idx in orphan_indices else acct["Id"],
            "Account": {
                "attributes": sf_attrs("Account", acct["Id"]),
                "Name": acct["Name"],
                "SwiftRoute_Client_ID__c": acct["SwiftRoute_Client_ID__c"],
            } if idx not in orphan_indices else None,
            "Status":        random.choices(
                ["Activated", "Activated", "Activated", "Draft", "Expired"],
                weights=[0.80, 0.05, 0.05, 0.05, 0.05]
            )[0],
            "StartDate":     sf_date(start),
            "EndDate":       sf_date(end),
            "ContractTerm":  12,
            "SignedDate__c": sf_date(signed),

            # Commercial terms
            "Contract_Type__c":          contract_type,
            "Committed_Monthly_Volume__c": acct["Contracted_Monthly_Volume__c"],
            "Discount_Rate__c":          acct["Discount_Rate__c"],
            "Net_Payment_Terms__c":      acct["Net_Payment_Terms__c"],
            "Auto_Renewal__c":           random.random() > 0.35,
            "Termination_Notice_Days__c": 60,
            "Primary_City__c":           acct["Primary_City__c"],
            "Account_Tier__c":           tier,

            # QUIRK 1: actual per-zone, per-service rates live in
            # Contract_Rate__c (a separate Salesforce custom object)
            # — not on this Contract record
            "_rate_note": (
                "QUIRK 1: per-service, per-zone rates are stored in "
                "Contract_Rate__c records linked to this contract. "
                "Two separate API calls needed for a complete picture."
            ),

            "CreatedDate":     sf_datetime(signed),
            "LastModifiedDate": sf_datetime(
                signed + timedelta(days=random.randint(1, 30))),
            "OwnerId": acct["OwnerId"],
        })

    random.seed(SEED)
    return contracts


# ══════════════════════════════════════════════════════════════════════════════
#  CONTRACT RATE BUILDER  (the critical reference table)
# ══════════════════════════════════════════════════════════════════════════════

def build_contract_rates(accounts, contracts):
    """
    Contract_Rate__c is a custom Salesforce object — each record defines
    the agreed rate for one service type in one zone for one contract.

    This IS the rate card. Without it you cannot calculate what SwiftRoute
    should bill a client for any given delivery.

    QUIRK 1: this requires a completely separate API query:
      SELECT * FROM Contract_Rate__c WHERE Contract__c = '...'
    It is not returned as part of the Contract record.
    """
    random.seed(820)
    rates = []

    contract_map = {c["AccountId"]: c for c in contracts if c["AccountId"]}

    for acct in accounts:
        contract = contract_map.get(acct["Id"])
        if not contract:
            continue   # orphaned contract — no rates

        city     = acct["Primary_City__c"]
        discount = acct["Discount_Rate__c"]
        zones    = ZONE_IDS.get(city, ZONE_IDS["denver"])

        # Determine which service types this client uses
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

            # For non-zone services (storage, fulfillment) one rate record
            if svc in ("fulfillment_pick", "storage"):
                rate_id = sf_id("a0B")
                rates.append({
                    "attributes": sf_attrs("Contract_Rate__c", rate_id),
                    "Id":           rate_id,
                    "Contract__c":  contract["Id"],
                    "Account__c":   acct["Id"],
                    "SwiftRoute_Client_ID__c": acct["SwiftRoute_Client_ID__c"],
                    "Service_Type__c": svc,
                    "Zone_ID__c":     None,   # not zone-specific
                    "Zone_Name__c":   None,
                    "Base_Rate__c":   base_rate,
                    "Discount_Rate__c": discount,
                    "Net_Rate__c":    round(base_rate * (1 - discount), 2),
                    "Unit__c": "per_unit" if svc == "fulfillment_pick"
                               else "per_pallet_per_month",
                    "Effective_Date__c": contract["StartDate"],
                    "CreatedDate": contract["CreatedDate"],
                })
            else:
                # Zone-specific rate — one record per zone
                for zone_id in zones:
                    rate_id = sf_id("a0B")
                    # Zone 9 Denver (remote) and ABQ Zone 3 carry surcharge
                    zone_surcharge = (
                        1.25 if zone_id in ("zone_den_9", "zone_abq_3")
                        else 1.10 if zone_id in ("zone_den_4", "zone_abq_4")
                        else 1.00
                    )
                    zone_rate = round(base_rate * zone_surcharge, 2)
                    net_rate  = round(zone_rate * (1 - discount), 2)

                    rates.append({
                        "attributes": sf_attrs("Contract_Rate__c", rate_id),
                        "Id":           rate_id,
                        "Contract__c":  contract["Id"],
                        "Account__c":   acct["Id"],
                        "SwiftRoute_Client_ID__c": acct["SwiftRoute_Client_ID__c"],
                        "Service_Type__c": svc,
                        "Zone_ID__c":     zone_id,
                        "Zone_Name__c":   zone_id.replace("_", " ").title(),
                        "Base_Rate__c":   zone_rate,
                        "Discount_Rate__c": discount,
                        "Net_Rate__c":    net_rate,
                        "Unit__c":        "per_delivery",
                        "Effective_Date__c": contract["StartDate"],
                        "CreatedDate":    contract["CreatedDate"],
                    })

    random.seed(SEED)
    return rates


# ══════════════════════════════════════════════════════════════════════════════
#  OPPORTUNITY BUILDER  (pipeline and renewal tracking)
# ══════════════════════════════════════════════════════════════════════════════

def build_opportunities(accounts):
    """
    Active pipeline opportunities + recently closed-won renewals.
    QUIRK 5: CloseDate on won deals is when the deal was signed,
    not when the contract expires — useless for renewal forecasting
    unless combined with Contract.EndDate.
    """
    random.seed(830)
    opps = []

    stages = ["Prospecting","Qualification","Proposal/Price Quote",
              "Negotiation","Closed Won","Closed Lost"]

    for acct in accounts:
        if random.random() < 0.35:
            continue   # not every account has an open opportunity

        opp_id    = sf_id("006")
        stage     = random.choices(
            stages,
            weights=[0.15, 0.15, 0.20, 0.20, 0.20, 0.10]
        )[0]

        close_dt  = (AS_OF - timedelta(days=random.randint(1, 180))
                     if stage in ("Closed Won", "Closed Lost")
                     else AS_OF + timedelta(days=random.randint(15, 120)))

        opps.append({
            "attributes": sf_attrs("Opportunity", opp_id),
            "Id":          opp_id,
            "AccountId":   acct["Id"],
            "Account": {
                "attributes": sf_attrs("Account", acct["Id"]),
                "Name": acct["Name"],
                "SwiftRoute_Client_ID__c": acct["SwiftRoute_Client_ID__c"],
            },
            "Name":        f"{acct['Name']} — Contract Renewal 2025",
            "StageName":   stage,
            "Amount":      round(
                random.randint(5000, 480000) * random.uniform(0.8, 1.2), 2),
            # QUIRK 5: CloseDate is deal-signed date, not contract-end date
            "CloseDate":   sf_date(close_dt),
            "Probability": {
                "Prospecting": 10, "Qualification": 25,
                "Proposal/Price Quote": 50, "Negotiation": 75,
                "Closed Won": 100, "Closed Lost": 0,
            }[stage],
            "Type":        "Renewal",
            "LeadSource":  random.choice([
                "Existing Customer", "Referral", "Web", "Cold Call",
            ]),
            "OwnerId":     acct["OwnerId"],
            "CreatedDate": sf_datetime(
                AS_OF - timedelta(days=random.randint(10, 200))),
            "LastActivityDate": sf_date(
                AS_OF - timedelta(days=random.randint(1, 30))),
            # QUIRK 6: custom fields
            "Contract_Type__c": acct["Contract_Type__c"],
            "Primary_City__c":  acct["Primary_City__c"],
            "Account_Tier__c":  acct["Account_Tier__c"],
        })

    random.seed(SEED)
    return opps


# ══════════════════════════════════════════════════════════════════════════════
#  WRITER
# ══════════════════════════════════════════════════════════════════════════════

def write_sf_pages(records, folder, object_type):
    """
    Salesforce response envelope:
    {"totalSize": N, "done": bool, "records": [...], "nextRecordsUrl": "..."}
    """
    os.makedirs(folder, exist_ok=True)
    pages      = [records[i:i+PAGE_SIZE]
                  for i in range(0, len(records), PAGE_SIZE)]
    total_pages = len(pages)

    for idx, page in enumerate(pages, start=1):
        is_last = idx == total_pages
        payload = {
            "totalSize":      len(records),
            "done":           is_last,
            # nextRecordsUrl is a URL path (not a token) — QUIRK specific to SF
            "nextRecordsUrl": (
                None if is_last
                else f"/services/data/{API_VERSION}/query/{object_type}-{idx+1}"
            ),
            "records": page,
        }
        fname = f"page_{str(idx).zfill(4)}.json"
        with open(os.path.join(folder, fname), "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2, ensure_ascii=False)

    return total_pages


# ══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════════

def main():
    print("SwiftRoute — Salesforce raw data generator")
    print("=" * 45)

    # Build all objects
    accounts  = build_accounts()
    contracts = build_contracts(accounts)
    rates     = build_contract_rates(accounts, contracts)
    opps      = build_opportunities(accounts)

    orphaned_contracts = [c for c in contracts if c["AccountId"] is None]
    custom_fields_example = [k for k in accounts[0].keys() if k.endswith("__c")]

    # Write pages
    a_pages = write_sf_pages(
        accounts,  os.path.join(OUTPUT_BASE, "accounts"),       "Account")
    c_pages = write_sf_pages(
        contracts, os.path.join(OUTPUT_BASE, "contracts"),      "Contract")
    r_pages = write_sf_pages(
        rates,     os.path.join(OUTPUT_BASE, "contract_rates"), "Contract_Rate__c")
    o_pages = write_sf_pages(
        opps,      os.path.join(OUTPUT_BASE, "opportunities"),  "Opportunity")

    # Summary
    print(f"Accounts          : {len(accounts):,}  ({a_pages} page)")
    print(f"Contracts         : {len(contracts):,}  ({c_pages} page)")
    print(f"  Orphaned        : {len(orphaned_contracts):,}  ← QUIRK 3")
    print(f"Contract rates    : {len(rates):,}  ({r_pages} pages)  ← QUIRK 1 (separate object)")
    print(f"Opportunities     : {len(opps):,}  ({o_pages} page)")
    print()
    print("Quirk verification:")
    print(f"  Custom fields   : {custom_fields_example}  ← QUIRK 6")
    print(f"  Orphaned ctrs   : {len(orphaned_contracts)} contracts with null AccountId")
    print(f"  Compound addr   : accounts[0].BillingAddress is object not string  ← QUIRK 2")
    print(f"  Rates are sep.  : {len(rates)} rate records in separate contract_rates/  ← QUIRK 1")
    print()
    print("Key things to notice when you open these files:")
    print("  1. Every record has attributes.type and attributes.url")
    print("  2. Pagination: nextRecordsUrl is a URL path, not a token")
    print("  3. BillingAddress is {street, city, state, postalCode, country}")
    print("  4. Custom fields end in __c — they power all SwiftRoute-specific data")
    print("  5. Contract rates are a SEPARATE query — never on the Contract record")
    print("  6. CloseDate on won Opportunities = signing date, not contract end")
    print(f"\nOutput: {OUTPUT_BASE}")


if __name__ == "__main__":
    main()
