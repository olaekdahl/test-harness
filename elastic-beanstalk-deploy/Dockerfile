# Use PostgreSQL 17 as the base image
FROM postgres:17

# Set PostgreSQL environment variables
ENV POSTGRES_USER=postgres
ENV POSTGRES_PASSWORD=postgres
ENV POSTGRES_DB=users

# Set environment variables for your application
ENV DB_USER=postgres
ENV DB_HOST=localhost
ENV DB_NAME=users
ENV DB_PASSWORD=postgres
ENV DB_PORT=5432

# Install Node.js
RUN apt-get update && apt-get install -y \
    curl \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Verify installations
RUN node --version && npm --version && psql --version

# Copy the database initialization script (optional)
WORKDIR /docker-entrypoint-initdb.d/
COPY init.sql /docker-entrypoint-initdb.d/init.sql

# Create a directory for the application
WORKDIR /app

# Copy package.json and package-lock.json
COPY package*.json ./

# Install Node.js dependencies
RUN npm install

# Copy the application code
COPY . .

# Expose and Node.js ports
EXPOSE 5000

# Add the entrypoint script
COPY entrypoint.sh /usr/local/bin/
# This is some weirdness that only happens when deploying using the AWS console
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Use the entrypoint script to start both PostgreSQL and Node.js
ENTRYPOINT ["entrypoint.sh"]