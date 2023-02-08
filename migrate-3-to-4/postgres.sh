#!/bin/bash

function import_postgres() {
    echo 'Importing Postgres'

    PG_POD=$(kubectl -n "$NAMESPACE" get pods | grep postgresql | tail -1 | awk '{print $1}')

    PG_PASSWORD=$(kubectl -n "$NAMESPACE" get secrets postgresql -o jsonpath="{.data.postgres-password}" | base64 --decode)

    # Server 3 and 4 both have a user named `postgres`.
    # The postgres dump will drop all resources before trying to create new ones, including the postgres user.
    # Remove the lines that would delete the postgres user.
    # this is not a problem when migrating from 2.19 becuase 2.19's username was 'circle'
    sed -i ".bak" '/DROP ROLE postgres/d' "$PG_BU"/circle.sql
    sed -i ".bak" '/CREATE ROLE postgres/d' "$PG_BU"/circle.sql
    sed -i ".bak" '/ALTER ROLE postgres WITH SUPERUSER INHERIT CREATEROLE CREATEDB LOGIN REPLICATION BYPASSRLS PASSWORD/d' "$PG_BU"/circle.sql

    # Note: This import assumes `pg_dumpall -c` was run to drop tables before ...importing into them.
    kubectl -n "$NAMESPACE" exec -i "$PG_POD" -- env PGPASSWORD="$PG_PASSWORD" psql -U postgres < "$PG_BU"/circle.sql
}