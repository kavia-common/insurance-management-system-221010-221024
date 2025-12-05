#!/bin/bash
set -euo pipefail

# Robust PostgreSQL startup script
DB_NAME="${DB_NAME:-myapp}"
DB_USER="${DB_USER:-appuser}"
DB_PASSWORD="${DB_PASSWORD:-dbuser123}"
# Keep configured port at 5001 unless overridden
DB_PORT="${DB_PORT:-5001}"
# Ensure PGDATA is correctly set
export PGDATA="${PGDATA:-/var/lib/postgresql/data}"

echo "Starting PostgreSQL setup on port ${DB_PORT}..."
echo "Using PGDATA=${PGDATA}"

# Resolve PostgreSQL version and set paths
PG_VERSION=$(ls /usr/lib/postgresql/ 2>/dev/null | head -1 || true)
if [ -z "${PG_VERSION}" ]; then
  echo "ERROR: PostgreSQL binaries not found under /usr/lib/postgresql"
  exit 1
fi
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"
echo "Found PostgreSQL version: ${PG_VERSION}"

# Ensure data directory exists with correct ownership/permissions
sudo mkdir -p "${PGDATA}"
sudo chown -R postgres:postgres "${PGDATA}"
sudo chmod 700 "${PGDATA}"

# Helper: readiness with exponential backoff
pg_ready_with_backoff() {
  local max_tries=${1:-10}
  local delay=0.5
  for ((i=1; i<=max_tries; i++)); do
    if sudo -u postgres "${PG_BIN}/pg_isready" -p "${DB_PORT}" -h 127.0.0.1 >/dev/null 2>&1; then
      return 0
    fi
    printf "Waiting for postgres to become ready on port %s (attempt %d/%d, sleep %.1fs)\n" "${DB_PORT}" "${i}" "${max_tries}" "${delay}"
    sleep "${delay}"
    # exponential backoff up to 5s
    delay=$(awk -v d="$delay" 'BEGIN { d*=2; if (d>5) d=5; print d }')
  done
  return 1
}

# 1) Detect if another Postgres is already running on this port
if sudo -u postgres "${PG_BIN}/pg_isready" -p "${DB_PORT}" -h 127.0.0.1 >/dev/null 2>&1; then
  echo "PostgreSQL already running on port ${DB_PORT}."
  echo "psql postgresql://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}" > db_connection.txt
  echo "Connection string saved to db_connection.txt"
  # Also export for db_visualizer
  cat > db_visualizer/postgres.env << EOF
export POSTGRES_URL="postgresql://localhost:${DB_PORT}/${DB_NAME}"
export POSTGRES_USER="${DB_USER}"
export POSTGRES_PASSWORD="${DB_PASSWORD}"
export POSTGRES_DB="${DB_NAME}"
export POSTGRES_PORT="${DB_PORT}"
EOF
  echo "Script stopped - server already running."
  exit 0
fi

# 2) Handle stale postmaster.pid if present but server not ready
POSTMASTER_PID_FILE="${PGDATA}/postmaster.pid"
if [ -f "${POSTMASTER_PID_FILE}" ]; then
  echo "Detected ${POSTMASTER_PID_FILE}. Checking if it's stale..."
  # Extract PID from first line of postmaster.pid
  POST_PID=$(head -n1 "${POSTMASTER_PID_FILE}" 2>/dev/null || echo "")
  if [ -n "${POST_PID}" ] && ps -p "${POST_PID}" -o comm= 2>/dev/null | grep -q "^postgres$"; then
    echo "A postgres process (PID ${POST_PID}) appears to be active. Re-checking readiness..."
    if pg_ready_with_backoff 6; then
      echo "Server became ready; skipping init/start."
      exit 0
    else
      echo "Process exists but not ready; proceeding cautiously."
    fi
  else
    echo "No active postgres process owns PID ${POST_PID:-N/A}; treating as stale lock."
  fi
  echo "Removing stale postmaster.pid"
  sudo rm -f "${POSTMASTER_PID_FILE}"
fi

# 3) Initialize data directory if needed
if [ ! -f "${PGDATA}/PG_VERSION" ]; then
  echo "Initializing PostgreSQL data directory at ${PGDATA}..."
  sudo -u postgres "${PG_BIN}/initdb" -D "${PGDATA}"
fi

# 4) Start PostgreSQL
echo "Starting PostgreSQL server on 0.0.0.0:${DB_PORT} ..."
# Use config override for port/host
sudo -u postgres "${PG_BIN}/postgres" -D "${PGDATA}" -p "${DB_PORT}" -h 0.0.0.0 &
POSTGRES_PID=$!

# 5) Wait until ready with exponential backoff
if pg_ready_with_backoff 12; then
  echo "PostgreSQL is ready on port ${DB_PORT}."
else
  echo "ERROR: PostgreSQL did not become ready on port ${DB_PORT}."
  # Ensure we only exit non-zero when start truly fails
  if ps -p "${POSTGRES_PID}" >/dev/null 2>&1; then
    echo "Postgres process (${POSTGRES_PID}) is running but not responding to pg_isready."
    # give one final grace period
    sleep 2
    if ! sudo -u postgres "${PG_BIN}/pg_isready" -p "${DB_PORT}" -h 127.0.0.1 >/dev/null 2>&1; then
      echo "Exiting with failure."
      exit 1
    fi
  else
    echo "Postgres process is not running. Exiting with failure."
    exit 1
  fi
fi

# 6) Create database and user; be idempotent
echo "Setting up database and user..."
sudo -u postgres "${PG_BIN}/createdb" -p "${DB_PORT}" "${DB_NAME}" 2>/dev/null || echo "Database '${DB_NAME}' might already exist"

sudo -u postgres "${PG_BIN}/psql" -p "${DB_PORT}" -d postgres << EOF
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
        CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}';
    END IF;
    ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';
END
\$\$;
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
EOF

sudo -u postgres "${PG_BIN}/psql" -p "${DB_PORT}" -d "${DB_NAME}" << EOF
GRANT USAGE ON SCHEMA public TO ${DB_USER};
GRANT CREATE ON SCHEMA public TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TYPES TO ${DB_USER};
GRANT ALL ON SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO ${DB_USER};
EOF

# 7) Persist connection and visualizer env
echo "psql postgresql://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}" > db_connection.txt
echo "Connection string saved to db_connection.txt"

cat > db_visualizer/postgres.env << EOF
export POSTGRES_URL="postgresql://localhost:${DB_PORT}/${DB_NAME}"
export POSTGRES_USER="${DB_USER}"
export POSTGRES_PASSWORD="${DB_PASSWORD}"
export POSTGRES_DB="${DB_NAME}"
export POSTGRES_PORT="${DB_PORT}"
EOF

echo "PostgreSQL setup complete!"
echo "Database: ${DB_NAME}"
echo "User: ${DB_USER}"
echo "Port: ${DB_PORT}"
echo "Environment variables saved to db_visualizer/postgres.env"
echo "To use with Node.js viewer, run: source db_visualizer/postgres.env"

echo "To connect to the database, use one of the following commands:"
echo "psql -h localhost -U ${DB_USER} -d ${DB_NAME} -p ${DB_PORT}"
echo "$(cat db_connection.txt)"
