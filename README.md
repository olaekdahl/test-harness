
# AWS ECS Deployment Scripts

This repository contains two scripts for deploying and updating applications on AWS ECS:

1. **`aws-ecs-setup.sh`**: Used to set up the initial AWS infrastructure and deploy the application for the first time.
2. **`continuous-deploy.sh`**: Used to update the deployed application by building and pushing new Docker images.

---

## Prerequisites

Before using the scripts, ensure the following tools are installed and configured:

### 1. Install AWS CLI

- Follow the [AWS CLI installation guide](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html).
- Verify the installation:

  ```bash
  aws --version
  ```

  Example output:

  ```text
  aws-cli/2.x.x Python/3.x.x Linux/Unix
  ```

- Configure AWS CLI:

  ```bash
  aws configure
  ```

  Provide:
  - **Access Key ID**: Your AWS access key.
  - **Secret Access Key**: Your AWS secret key.
  - **Default Region**: e.g., `us-west-1`.
  - **Output Format**: e.g., `json`.

---

### 2. Install Docker

- Follow the [Docker installation guide](https://docs.docker.com/get-docker/).
- Verify the installation:

  ```bash
  docker --version
  ```

  Example output:

  ```text
  Docker version 20.x.x, build xxxxx
  ```

- Ensure you can run Docker commands as your current user:

  ```bash
  docker info
  ```

---

## Scripts Overview

### `aws-ecs-setup.sh`

This script sets up AWS infrastructure for deploying a containerized application to ECS. It creates:

- VPC, Subnet, Internet Gateway, and Security Group
- ECS Cluster, Task Definition, and Service
- ECR Repository for Docker images
- CloudWatch Log Group

#### Usage:

Run this script **once** to set up the infrastructure and deploy the application for the first time.

1. Make the script executable:

   ```bash
   chmod +x aws-ecs-setup.sh
   ```

2. Run the script:

   ```bash
   ./aws-ecs-setup.sh
   ```

3. The script outputs important information such as:
   - VPC ID
   - Subnet ID
   - ECS Cluster and Service Name
   - ECR Repository URI
   - Public IP Address of the deployed container

---

### `continuous-deploy.sh`

This script is used for continuous deployment of updated versions of the application to ECS. It:

1. Builds the Docker image.
2. Pushes the image to ECR.
3. Updates the ECS Service with the new image.

#### Usage:

Run this script whenever you want to deploy a new version of the application.

1. Make the script executable:

   ```bash
   chmod +x continuous-deploy.sh
   ```

2. Run the script:

   ```bash
   ./continuous-deploy.sh
   ```

3. The script will:
   - Build the Docker image using the latest code.
   - Push the new image to the ECR repository.
   - Update the ECS service with the new image.

---

## Summary

1. Run `aws-ecs-setup.sh` once to set up the AWS infrastructure and deploy the application.
2. Use `continuous-deploy.sh` to build, push, and deploy updates to ECS.

---

Let me know if you encounter any issues or need further assistance!
