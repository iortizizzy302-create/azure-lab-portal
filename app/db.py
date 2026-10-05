"""Database layer.

In Azure the app talks to Azure SQL Database through pyodbc (set
AZURE_SQL_CONNECTION). On your laptop it falls back to a local SQLite
file so you can run the portal with zero cloud setup.

Every query uses '?' placeholders, which both pyodbc and sqlite3 accept.
"""
import logging
import os
import random
import sqlite3
import time
from datetime import date, datetime, timedelta
from decimal import Decimal

log = logging.getLogger("labportal")

AZURE_CONN = os.getenv("AZURE_SQL_CONNECTION")
LOCAL_DB = os.getenv("LOCAL_DB_PATH", "labportal.db")


def dialect():
    return "mssql" if AZURE_CONN else "sqlite"


def get_conn():
    if not AZURE_CONN:
        return sqlite3.connect(LOCAL_DB)

    import pyodbc
    # Serverless Azure SQL auto-pauses; the first connection after a pause
    # can fail while the database resumes, so retry a few times.
    for attempt in range(1, 4):
        try:
            return pyodbc.connect(AZURE_CONN, timeout=30)
        except pyodbc.Error as exc:
            log.warning("sql_connect_retry", extra={"attempt": attempt, "error": str(exc)[:200]})
            if attempt == 3:
                raise
            time.sleep(5 * attempt)


def _clean(value):
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, (date, datetime)):
        return value.isoformat()[:10]
    return value


def query(sql, params=()):
    """Run a SELECT and return rows as a list of dicts (an array of records)."""
    conn = get_conn()
    try:
        cur = conn.cursor()
        cur.execute(sql, params)
        cols = [c[0] for c in cur.description]
        return [{c: _clean(v) for c, v in zip(cols, row)} for row in cur.fetchall()]
    finally:
        conn.close()


# ------------------------------------------------------------------ schema

SCHEMA = """
CREATE TABLE clients (
    client_id     INT PRIMARY KEY,
    name          NVARCHAR(100) NOT NULL,
    account_no    VARCHAR(20)  NOT NULL,
    contact_email VARCHAR(120)
);
CREATE TABLE test_catalog (
    test_code     VARCHAR(8) PRIMARY KEY,
    test_name     NVARCHAR(60) NOT NULL,
    units         VARCHAR(12),
    ref_low       DECIMAL(9,2) NOT NULL,
    ref_high      DECIMAL(9,2) NOT NULL,
    display_order INT NOT NULL
);
CREATE TABLE samples (
    sample_id     INT PRIMARY KEY,
    client_id     INT NOT NULL REFERENCES clients(client_id),
    accession_no  VARCHAR(20) NOT NULL,
    subject_name  NVARCHAR(60),
    sample_type   VARCHAR(20),
    collected_on  DATE,
    received_on   DATE,
    status        VARCHAR(12)
);
CREATE TABLE test_results (
    result_id     {identity},
    sample_id     INT NOT NULL REFERENCES samples(sample_id),
    test_code     VARCHAR(8) NOT NULL REFERENCES test_catalog(test_code),
    result_value  DECIMAL(9,2) NOT NULL,
    resulted_at   DATETIME2
);
CREATE INDEX ix_samples_client ON samples(client_id);
CREATE INDEX ix_results_sample ON test_results(sample_id);
"""

IDENTITY = {
    "mssql": "INT IDENTITY(1,1) PRIMARY KEY",
    "sqlite": "INTEGER PRIMARY KEY AUTOINCREMENT",
}

# Fake chemistry panel: code, name, units, low, high
CATALOG = [
    ("GLU",  "Glucose",                "mg/dL",  70,   110),
    ("BUN",  "Blood urea nitrogen",    "mg/dL",  7,    20),
    ("CREA", "Creatinine",             "mg/dL",  0.6,  1.3),
    ("ALT",  "Alanine aminotransferase", "U/L",  7,    56),
    ("ALP",  "Alkaline phosphatase",   "U/L",    44,   147),
    ("TP",   "Total protein",          "g/dL",   6.0,  8.3),
    ("ALB",  "Albumin",                "g/dL",   3.5,  5.0),
    ("NA",   "Sodium",                 "mmol/L", 135,  145),
    ("K",    "Potassium",              "mmol/L", 3.5,  5.1),
]

CLIENTS = [
    (1001, "Hill Country Family Clinic", "HCFC-20418", "lab@hillcountry.example"),
    (1002, "Mission Trail Medical Group", "MTMG-55102", "results@missiontrail.example"),
    (1003, "Guadalupe Valley Health",    "GVH-30877",  "orders@gvhealth.example"),
    (1004, "Cibolo Creek Research",      "CCR-71230",  "study@cibolocreek.example"),
]

FIRST = ["Avery", "Jordan", "Riley", "Morgan", "Casey", "Quinn", "Rowan", "Elena", "Mateo", "Lucia"]
LAST = ["Garza", "Nguyen", "Whitaker", "Salinas", "Okafor", "Brennan", "Delgado", "Holt"]


def _fake_rows():
    rng = random.Random(42)  # same fake data every time
    samples, results = [], []
    sample_id = 50001
    today = date(2026, 9, 30)
    for client_id, *_ in CLIENTS:
        for _ in range(6):
            collected = today - timedelta(days=rng.randint(1, 40))
            received = collected + timedelta(days=1)
            pending = rng.random() < 0.15
            samples.append((
                sample_id, client_id, f"VA{sample_id}{rng.randint(10, 99)}",
                f"{rng.choice(FIRST)} {rng.choice(LAST)}", "Serum",
                collected.isoformat(), received.isoformat(),
                "In progress" if pending else "Complete",
            ))
            if not pending:
                resulted = datetime.combine(received, datetime.min.time()) + timedelta(hours=rng.randint(4, 30))
                for code, _n, _u, low, high in CATALOG:
                    span = high - low
                    # ~80% inside range, the rest pushed out either way
                    if rng.random() < 0.8:
                        val = rng.uniform(low + span * 0.05, high - span * 0.05)
                    elif rng.random() < 0.5:
                        val = rng.uniform(high, high + span * 0.6)
                    else:
                        val = rng.uniform(max(0, low - span * 0.5), low)
                    results.append((sample_id, code, round(val, 2), resulted.strftime("%Y-%m-%d %H:%M:%S")))
            sample_id += 1
    return samples, results


def init_db():
    """Create tables and load fake data the first time the app starts."""
    try:
        if query("SELECT COUNT(*) AS n FROM clients")[0]["n"] > 0:
            log.info("db_already_seeded", extra={"dialect": dialect()})
            return
    except Exception:
        pass  # tables don't exist yet

    conn = get_conn()
    try:
        cur = conn.cursor()
        for stmt in SCHEMA.format(identity=IDENTITY[dialect()]).split(";"):
            if stmt.strip():
                cur.execute(stmt)
        samples, results = _fake_rows()
        cur.executemany("INSERT INTO clients VALUES (?,?,?,?)", CLIENTS)
        cur.executemany(
            "INSERT INTO test_catalog VALUES (?,?,?,?,?,?)",
            [(c, n, u, lo, hi, i) for i, (c, n, u, lo, hi) in enumerate(CATALOG)],
        )
        cur.executemany("INSERT INTO samples VALUES (?,?,?,?,?,?,?,?)", samples)
        cur.executemany(
            "INSERT INTO test_results (sample_id, test_code, result_value, resulted_at) VALUES (?,?,?,?)",
            results,
        )
        conn.commit()
        log.info("db_seeded", extra={"dialect": dialect(), "samples": len(samples), "results": len(results)})
    finally:
        conn.close()
