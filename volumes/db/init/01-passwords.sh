#!/bin/bash
# =============================================================================
# 01-passwords.sh – Set passwords for all Supabase service accounts
# =============================================================================
# Runs AFTER data.sql (scripts execute alphabetically: 00-data.sql, then this).
# Shell scripts in docker-entrypoint-initdb.d have the full environment
# available, so $POSTGRES_PASSWORD is readable here.
#
# The supabase/postgres image executes initdb scripts as supabase_admin, which
# is a superuser, so ALTER USER ... PASSWORD works without restriction.
# =============================================================================

set -euo pipefail

: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be set}"

psql -v ON_ERROR_STOP=1 --username supabase_admin --dbname postgres <<-EOSQL
    ALTER USER postgres                   WITH PASSWORD '${POSTGRES_PASSWORD}';
    ALTER USER authenticator              WITH PASSWORD '${POSTGRES_PASSWORD}';
    ALTER USER pgbouncer                  WITH PASSWORD '${POSTGRES_PASSWORD}';
    ALTER USER supabase_auth_admin        WITH PASSWORD '${POSTGRES_PASSWORD}';
    ALTER USER supabase_storage_admin     WITH PASSWORD '${POSTGRES_PASSWORD}';
    ALTER USER supabase_replication_admin WITH PASSWORD '${POSTGRES_PASSWORD}';
    ALTER USER supabase_read_only_user    WITH PASSWORD '${POSTGRES_PASSWORD}';
    ALTER USER supabase_etl_admin         WITH PASSWORD '${POSTGRES_PASSWORD}';
EOSQL
