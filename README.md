# Alamo Valley Labs specimen portal (mock)

A practice client portal for lab test results. Everything is fake: the lab, the
clients, the subjects and every result.

```
Browser ──> Azure App Service (Linux container)
              │  Flask + gunicorn (Python)
              │    ├── Azure SQL Database ── clients, samples, test_catalog, test_results
              │    └── COBOL program (GnuCOBOL) ── loads results into an OCCURS table,
              │                                     flags H/L/N, computes range position
              └── logs ──> Application Insights ──> Log Analytics workspace (KQL)
                      └──> App Service diagnostic logs ──┘
```

## How the pieces fit

1. A client picks their account and opens a sample.
2. Flask runs a SQL join and gets that sample's results back as a list of rows.
3. The rows are written to a fixed-width file and handed to `cobol/RESULTS.cbl`.
4. COBOL reads them into `RESULT-TABLE` (an `OCCURS 200 TIMES` array), checks each
   value against its reference range, works out where it sits (0 = low limit,
   100 = high limit) and prints `R|...` and `S|...` lines.
5. Flask parses that output and draws the results table with a range bar per test.
6. Every step writes a structured log line (`cobol_evaluated`, `results_viewed`,
   `cross_client_access_denied`, ...) that you can query in Azure.

## Project layout

| Path | What it is |
|---|---|
| `cobol/RESULTS.cbl` | The COBOL evaluator (the array lives here) |
| `app/main.py` | Flask routes and Azure Monitor setup |
| `app/db.py` | Azure SQL / SQLite access, schema, fake data generator |
| `app/cobol_bridge.py` | Python to COBOL hand-off and parsing |
| `sql/` | T-SQL schema and practice queries for the portal Query editor |
| `logs/queries.kql` | 12 KQL queries for Log Analytics |
| `infra/deploy.ps1` | One-shot PowerShell deploy to Azure |
| `Dockerfile` | Python + GnuCOBOL + ODBC Driver 18 image |

## Run it on your laptop

Quickest (Python only; COBOL step uses a Python stand-in and the page says so):

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install flask
python -m flask --app app.main run
```

Open http://127.0.0.1:5000. Data goes into a local `labportal.db` SQLite file.

With the real COBOL step (needs Docker Desktop):

```powershell
docker build -t labportal .
docker run -p 8000:8000 labportal
```

Open http://localhost:8000. The results page footer should read
"Range checks run by COBOL (GnuCOBOL)."

## Deploy to Azure

Prereqs: an Azure subscription and the Azure CLI (`winget install Microsoft.AzureCLI`,
then `az upgrade` if it's already installed).

```powershell
az login
.\infra\deploy.ps1
```

The script builds the image in Azure Container Registry (so Docker isn't required
for this part), creates the SQL database, wires up Application Insights and Log
Analytics, and prints the site URL. The app creates its tables and loads the fake
data on first start.

If SQL creation fails with a region capacity error, rerun with another region:
`.\infra\deploy.ps1 -Location centralus`.

These resources cost money while they exist (mainly the B1 App Service plan and
the container registry). When you're done practicing:

```powershell
az group delete -n rg-avlabs-portal --yes --no-wait
```

## Practicing with Azure logs

Generate some traffic first: sign in as a few accounts, open samples, then try these:

* Visit `/samples/50001` while signed in as a different account. That's a
  `cross_client_access_denied` warning.
* Visit `/demo/fail` a few times. Those are exceptions with stack traces.
* Visit `/samples/99999` for 404s.

Then in the Azure portal, open the Log Analytics workspace, choose **Logs**, and
work through `logs/queries.kql`. Other places worth knowing:

* **App Service > Log stream** for live container output (or `az webapp log tail`).
* **Application Insights > Failures** and **Performance** for the built-in views of
  the same data.
* **Application Insights > Transaction search** to follow one request end to end.
* **Alerts > Create > Alert rule** on the Log Analytics workspace using query 6
  (cross-client access) with "number of results greater than 0" to build an
  alert from a KQL query.

## Talking points

* Why COBOL behind a web app: lots of labs, banks and government systems still
  run COBOL business rules; wrapping them behind a modern API instead of
  rewriting them is a common modernization pattern.
* The fixed-width record and implied-decimal `PIC 9(5)V99` format is how COBOL
  systems usually exchange data.
* Serverless Azure SQL pauses when idle; the app retries the first connection
  and logs each retry, which you can see with query 8.
* Clients can only see their own samples, and attempts to see others are
  logged and alertable.
* Secrets (SQL connection string, App Insights key) live in App Service settings,
  not in code. A next step would be Managed Identity and Key Vault.
