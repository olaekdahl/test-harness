#!/bin/bash

# Create socket directory if missing
mkdir -p /var/run/postgresql
chown -R postgres:postgres /var/run/postgresql

# Start PostgreSQL
echo "Starting PostgreSQL..."
docker-entrypoint.sh postgres &

# Wait for PostgreSQL to become available
echo "Waiting for PostgreSQL to become available..."
until pg_isready -h localhost -p 5432 -U postgres; do
    sleep 1
done

echo "PostgreSQL is ready."

# Start FastAPI
echo "Starting FastAPI..."
exec uvicorn app:app --host 0.0.0.0 --port 8000