# Lab portal: Python web app + GnuCOBOL + Microsoft ODBC driver for Azure SQL
FROM python:3.12-slim-bookworm

ENV PYTHONUNBUFFERED=1 \
    COBOL_BIN=/app/bin/results

# GnuCOBOL compiler/runtime + ODBC Driver 18 for SQL Server
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl gnupg ca-certificates gnucobol unixodbc \
 && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg \
 && curl -fsSL https://packages.microsoft.com/config/debian/12/prod.list -o /etc/apt/sources.list.d/mssql-release.list \
 && apt-get update \
 && ACCEPT_EULA=Y apt-get install -y --no-install-recommends msodbcsql18 \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Compile the COBOL evaluator into a native executable
COPY cobol/ cobol/
RUN mkdir -p bin && cobc -x -free -o bin/results cobol/RESULTS.cbl

COPY app/ app/

EXPOSE 8000
# --preload runs db.init_db() once before workers fork
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "2", "--preload", "--access-logfile", "-", "app.main:app"]
