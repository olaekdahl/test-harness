# Use an official OpenJDK runtime as a parent image
FROM openjdk:17-jdk-slim

# Set the working directory
WORKDIR /app

# Copy the Spring Boot application JAR file into the container
# Replace 'application.jar' with the name of your Spring Boot JAR file
COPY target/application.jar ./application.jar

# Expose the default port used by Spring Boot
EXPOSE 8080

# Command to run the application
CMD ["java", "-jar", "application.jar"]