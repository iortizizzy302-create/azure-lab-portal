"""Hands a sample's results to the compiled COBOL program and reads back
its verdicts.

Flow: list of result dicts (Python array) -> fixed-width file -> COBOL loads
it into its OCCURS table (COBOL array) -> COBOL prints R|...|S| lines -> parsed
back into a list of dicts.

If the COBOL binary isn't present (e.g. running on Windows without Docker),
a Python version of the same rules runs instead and the page says so.
"""
import logging
import os
import subprocess
import tempfile
import time

log = logging.getLogger("labportal")

COBOL_BIN = os.getenv("COBOL_BIN", "/app/bin/results")


def _fixed(n):
    """Encode a number as COBOL PIC 9(5)V99: 7 digits, implied decimal."""
    cents = int(round(max(0.0, min(float(n), 99999.99)) * 100))
    return f"{cents:07d}"


def _to_record(r):
    return f"{r['test_code'][:8]:<8}{_fixed(r['result_value'])}{_fixed(r['ref_low'])}{_fixed(r['ref_high'])}"


def _python_rules(rows):
    out, summary = [], {"total": 0, "normal": 0, "high": 0, "low": 0}
    for r in rows:
        v, lo, hi = r["result_value"], r["ref_low"], r["ref_high"]
        flag = "L" if v < lo else "H" if v > hi else "N"
        pos = round((v - lo) * 100 / (hi - lo), 1) if hi > lo else 50.0
        out.append({"test_code": r["test_code"], "value": v, "flag": flag, "position": pos})
        summary["total"] += 1
        summary[{"L": "low", "H": "high", "N": "normal"}[flag]] += 1
    return out, summary


def evaluate(rows, sample_id=None):
    """Returns (evaluated_rows, summary, engine_name)."""
    if not rows:
        return [], {"total": 0, "normal": 0, "high": 0, "low": 0}, "none"

    if not os.path.exists(COBOL_BIN):
        out, summary = _python_rules(rows)
        log.warning("cobol_binary_missing", extra={"sample_id": sample_id, "engine": "python"})
        return out, summary, "Python fallback"

    started = time.perf_counter()
    with tempfile.NamedTemporaryFile("w", suffix=".dat", delete=False) as f:
        f.write("\n".join(_to_record(r) for r in rows) + "\n")
        path = f.name
    try:
        proc = subprocess.run([COBOL_BIN, path], capture_output=True, text=True, timeout=10)
    finally:
        os.unlink(path)
    elapsed_ms = round((time.perf_counter() - started) * 1000, 2)

    out, summary = [], None
    for line in proc.stdout.splitlines():
        parts = line.strip().split("|")
        if parts[0] == "R":
            out.append({"test_code": parts[1], "value": float(parts[2]),
                        "flag": parts[3], "position": float(parts[4])})
        elif parts[0] == "S":
            summary = dict(zip(["total", "normal", "high", "low"], map(int, parts[1:5])))
        elif parts[0] == "E":
            log.error("cobol_error", extra={"sample_id": sample_id, "detail": line})

    if proc.returncode != 0 or summary is None:
        log.error("cobol_failed", extra={"sample_id": sample_id, "returncode": proc.returncode,
                                         "stderr": proc.stderr[:500]})
        raise RuntimeError("COBOL evaluator failed")

    log.info("cobol_evaluated", extra={
        "sample_id": sample_id, "duration_ms": elapsed_ms, "result_count": summary["total"],
        "flagged_high": summary["high"], "flagged_low": summary["low"]})
    return out, summary, "COBOL (GnuCOBOL)"
