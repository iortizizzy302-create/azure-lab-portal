"""Specimen client portal (mock). All data is fake.

Logging goes to two places:
  * stdout  -> App Service console logs -> Log Analytics (AppServiceConsoleLogs)
  * Azure Monitor OpenTelemetry -> Application Insights (AppRequests,
    AppTraces, AppExceptions, AppDependencies) when
    APPLICATIONINSIGHTS_CONNECTION_STRING is set.
"""
import logging
import os

# Must run before Flask is imported so requests get auto-instrumented.
if os.getenv("APPLICATIONINSIGHTS_CONNECTION_STRING"):
    from azure.monitor.opentelemetry import configure_azure_monitor
    configure_azure_monitor(logger_name="labportal")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("labportal")
log.setLevel(logging.INFO)

from flask import Flask, abort, jsonify, redirect, render_template, request, session, url_for  # noqa: E402

from app import cobol_bridge, db  # noqa: E402

app = Flask(__name__)
app.secret_key = os.getenv("FLASK_SECRET", "dev-only-not-secret")
DEMO_TOOLS = os.getenv("DEMO_TOOLS", "true").lower() == "true"

db.init_db()


def current_client():
    cid = session.get("client_id")
    if not cid:
        return None
    rows = db.query("SELECT * FROM clients WHERE client_id = ?", (cid,))
    return rows[0] if rows else None


def load_sample(sample_id, client):
    rows = db.query("SELECT * FROM samples WHERE sample_id = ?", (sample_id,))
    if not rows:
        log.warning("sample_not_found", extra={"sample_id": sample_id, "client_id": client["client_id"]})
        abort(404)
    sample = rows[0]
    if sample["client_id"] != client["client_id"]:
        # Good one to alert on in Azure Monitor
        log.warning("cross_client_access_denied", extra={
            "sample_id": sample_id, "client_id": client["client_id"],
            "owner_client_id": sample["client_id"], "client_ip": request.remote_addr})
        abort(403)
    return sample


def load_results(sample_id):
    # Rows come back as a list (array) of dicts, one per test
    return db.query(
        """SELECT r.test_code, c.test_name, c.units, c.ref_low, c.ref_high, r.result_value
           FROM test_results r
           JOIN test_catalog c ON c.test_code = r.test_code
           WHERE r.sample_id = ?
           ORDER BY c.display_order""",
        (sample_id,),
    )


@app.route("/", methods=["GET", "POST"])
def sign_in():
    clients = db.query("SELECT client_id, name, account_no FROM clients ORDER BY name")
    if request.method == "POST":
        cid = int(request.form["client_id"])
        session["client_id"] = cid
        log.info("client_signed_in", extra={"client_id": cid})
        return redirect(url_for("portal"))
    return render_template("sign_in.html", clients=clients)


@app.route("/sign-out")
def sign_out():
    log.info("client_signed_out", extra={"client_id": session.get("client_id")})
    session.clear()
    return redirect(url_for("sign_in"))


@app.route("/samples")
def portal():
    client = current_client()
    if not client:
        return redirect(url_for("sign_in"))
    samples = db.query(
        """SELECT s.*,
                  (SELECT COUNT(*) FROM test_results r
                   JOIN test_catalog c ON c.test_code = r.test_code
                   WHERE r.sample_id = s.sample_id
                     AND (r.result_value < c.ref_low OR r.result_value > c.ref_high)) AS flagged
           FROM samples s WHERE s.client_id = ?
           ORDER BY s.collected_on DESC""",
        (client["client_id"],),
    )
    log.info("sample_list_viewed", extra={"client_id": client["client_id"], "sample_count": len(samples)})
    return render_template("samples.html", client=client, samples=samples)


@app.route("/samples/<int:sample_id>")
def sample_detail(sample_id):
    client = current_client()
    if not client:
        return redirect(url_for("sign_in"))
    sample = load_sample(sample_id, client)
    results = load_results(sample_id)
    evaluated, summary, engine = cobol_bridge.evaluate(results, sample_id=sample_id)

    by_code = {e["test_code"]: e for e in evaluated}
    for r in results:
        e = by_code.get(r["test_code"], {})
        r["flag"] = e.get("flag", "N")
        # Clamp marker to the drawn track (-50% .. 150% of the range)
        r["marker"] = max(-50.0, min(150.0, e.get("position", 50.0)))

    log.info("results_viewed", extra={"client_id": client["client_id"], "sample_id": sample_id,
                                      "engine": engine, "flagged": summary["high"] + summary["low"]})
    return render_template("sample.html", client=client, sample=sample, results=results,
                           summary=summary, engine=engine)


@app.route("/api/samples/<int:sample_id>/results")
def sample_api(sample_id):
    client = current_client()
    if not client:
        return jsonify(error="Sign in first"), 401
    sample = load_sample(sample_id, client)
    results = load_results(sample_id)
    evaluated, summary, engine = cobol_bridge.evaluate(results, sample_id=sample_id)
    return jsonify(sample=sample, results=results, evaluation=evaluated, summary=summary, engine=engine)


@app.route("/health")
def health():
    db.query("SELECT 1 AS ok")
    return {"status": "ok", "database": db.dialect()}


@app.route("/demo/fail")
def demo_fail():
    """Throws on purpose so you have exceptions to find in the logs."""
    if not DEMO_TOOLS:
        abort(404)
    log.error("demo_failure_triggered", extra={"client_id": session.get("client_id")})
    raise RuntimeError("Demo exception: intentional failure for log practice")


@app.errorhandler(403)
def forbidden(_e):
    return render_template("message.html", title="That sample belongs to another account",
                           body="Go back to your samples and pick one from your list."), 403


@app.errorhandler(404)
def not_found(_e):
    return render_template("message.html", title="No sample with that number",
                           body="Check the accession number and try again."), 404
