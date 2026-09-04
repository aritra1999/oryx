#!/usr/bin/env bash
# Creates the affine and nextcloud databases in the shared postgres instance.
# Runs automatically on first postgres startup.
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    CREATE DATABASE affine;
    CREATE DATABASE nextcloud;
    GRANT ALL PRIVILEGES ON DATABASE affine TO $POSTGRES_USER;
    GRANT ALL PRIVILEGES ON DATABASE nextcloud TO $POSTGRES_USER;
EOSQL
