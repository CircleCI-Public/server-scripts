#!/bin/bash

function import_postgres() {
    echo '...importing Postgres...'

    PG_POD=$(kubectl -n "$NAMESPACE" get pods | grep postgresql | tail -1 | awk '{print $1}')
    PG_PASSWORD=$(kubectl -n "$NAMESPACE" get secrets postgresql -o jsonpath="{.data.postgresql-password}" | base64 --decode)

    # Note: This import assumes `pg_dumpall -c` was run to drop tables before ...importing into them.
    kubectl -n "$NAMESPACE" exec -i "$PG_POD" -- env PGPASSWORD="$PG_PASSWORD" psql -U postgres < "$PG_BU"/circle.sql
}