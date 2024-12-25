# Use PostgreSQL as the base image
FROM postgres:17

# Install Java and other necessary tools
RUN apt-get update && apt-get install -y openjdk-17-jdk curl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Verify Java installation
RUN java -version

# Set environment variables for PostgreSQL
ENV POSTGRES_USER=postgres
ENV POSTGRES_PASSWORD=postgres
ENV POSTGRES_DB=users

# Create a directory for the Spring Boot app
WORKDIR /app

# Copy the Spring Boot JAR file into the container
# Replace "app.jar" with the actual name of your built JAR file
COPY target/demo-0.0.1-SNAPSHOT.jar /app/demo-0.0.1-SNAPSHOT.jar

# Copy the database initialization script (optional)
COPY init.sql /docker-entrypoint-initdb.d/init.sql

# Use the entrypoint script
COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["entrypoint.sh"]

# Expose Spring Boot (8080) ports
EXPOSE 8080