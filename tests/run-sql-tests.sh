#!/usr/bin/env bash
# Loads Supabase stubs + supabase-schema.sql into a throwaway database (pm_test)
# and runs every tests/sql/*.test.sql. Uses PGHOST/PGPORT/PGUSER from the environment.
set -u
cd "$(dirname "$0")/.."
export PGUSER="${PGUSER:-postgres}"
export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning"
DB=pm_test
psql -X -q -d postgres -c "drop database if exists $DB" -c "create database $DB" || exit 1
trap 'psql -X -q -d postgres -c "drop database if exists $DB" >/dev/null 2>&1' EXIT
run() { psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f "$1" >/dev/null; }
run tests/sql/supabase-stubs.sql || { echo "FAIL stubs"; exit 1; }
run supabase-schema.sql || { echo "FAIL supabase-schema.sql"; exit 1; }
fail=0
for f in tests/sql/*.test.sql; do
  [ -e "$f" ] || continue
  if out=$(psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f "$f" 2>&1); then
    echo "PASS $f"
  else
    echo "FAIL $f"; echo "$out"; fail=1
  fi
done
exit $fail
