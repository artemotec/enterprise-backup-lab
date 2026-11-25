#!/usr/bin/env bash
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    ALTER SYSTEM SET wal_level = 'replica';
    ALTER SYSTEM SET archive_mode = 'on';
    ALTER SYSTEM SET archive_command = 'pgbackrest --stanza=prod archive-push %p';
    ALTER SYSTEM SET archive_timeout = '60';
    ALTER SYSTEM SET max_wal_senders = '3';
EOSQL

pgbackrest --stanza=prod --no-online stanza-create
