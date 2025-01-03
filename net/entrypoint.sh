#!/bin/bash

# Create necessary directories
mkdir -p /var/lib/postgresql/15/main /var/run/postgresql
chown -R postgres:postgres /var/lib/postgresql /var/run/postgresql
chmod -R 700 /var/lib/postgresql

# Modify pg_hba.conf to allow passwordless authentication temporarily
PG_HBA_CONF="/etc/postgresql/15/main/pg_hba.conf"
echo "local   all   postgres                                trust" > "$PG_HBA_CONF"

# Start PostgreSQL temporarily
echo "Starting PostgreSQL temporarily..."
su - postgres -c "/usr/lib/postgresql/15/bin/pg_ctl -D /var/lib/postgresql/15/main -l /var/lib/postgresql/logfile start -o '-c config_file=/etc/postgresql/15/main/postgresql.conf'"

# Set the password for the postgres user
echo "Setting password for postgres user..."
su - postgres -c "psql -c \"ALTER USER postgres WITH PASSWORD '$POSTGRES_PASSWORD';\""

# Stop PostgreSQL after setting the password
echo "Stopping temporary PostgreSQL instance..."
su - postgres -c "/usr/lib/postgresql/15/bin/pg_ctl -D /var/lib/postgresql/15/main stop"

# Restore pg_hba.conf for secure authentication
echo "Restoring pg_hba.conf for secure authentication..."
cat <<EOL > "$PG_HBA_CONF"
# Database administrative login by Unix domain socket
local   all   postgres                                md5

# Other default rules...
local   all   all                                     md5
host    all   all             127.0.0.1/32            scram-sha-256
host    all   all             ::1/128                 scram-sha-256
EOL

# Start PostgreSQL with explicit configuration file
echo "Starting PostgreSQL..."
su - postgres -c "/usr/lib/postgresql/15/bin/pg_ctl -D /var/lib/postgresql/15/main -l /var/lib/postgresql/logfile start -o '-c config_file=/etc/postgresql/15/main/postgresql.conf'"

# Wait for PostgreSQL to become ready
echo "Waiting for PostgreSQL to become available..."
until su - postgres -c "pg_isready -h localhost -p 5432 -U $POSTGRES_USER -d $POSTGRES_DB"; do
    sleep 1
done
echo "PostgreSQL is ready."

# Run the init.sql script
if [ -f /init-scripts/init.sql ]; then
    echo "Running initialization script..."
    su - postgres -c "PGPASSWORD=postgres psql -U postgres -f /init-scripts/init.sql"
    echo "Initialization script executed successfully."
else
    echo "Initialization script not found."
fi

# Start the .NET application
echo "Starting .NET 9 Web API..."
exec dotnet /app/UserApi.dll --urls http://0.0.0.0:5000