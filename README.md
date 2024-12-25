# AWS ECS Deployment Scripts

**_NOTE:_**  Only the Python example is working at the moment.

This repository contains two scripts for deploying and updating applications on AWS ECS:

1. **`aws-ecs-setup.sh`**: Used to set up the initial AWS infrastructure and deploy the application for the first time.
2. **`continuous-deploy.sh`**: Used to update the deployed application by building and pushing new Docker images.
3. Use **`<language>/init.sql`** to seed Postgres database.

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

### 3. Health Check

Make sure your application has an endpoint at this route "/api/health" in order for the ECS health check to work. The route can return anything and doesn't have to be a "real" route.

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
2. Update script variables:

```bash
LANGUAGE="<language>" # python, net, java, or node
DOCKER_FILE="<dockerfile>" # ex. "Dockerfile.python"
REGION=<aws region> #ex. "us-west-2"
NAME=<name prefix> # ex. "python" but can be anything
CONTAINER_PORT=<container port> # ex. 8000, 3001, etc.
HOST_PORT=<host port> # must match CONTAINER_PORT
```

3. Run the script:

   ```bash
   ./aws-ecs-setup.sh
   ```

4. The script outputs important information such as:

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
2. Update script variables match aws-ecs-setup.sh variables:

```bash
LANGUAGE=<match aws-ecs-setup.sh value>
DOCKER_FILE=<match aws-ecs-setup.sh value>
REGION=<match aws-ecs-setup.sh value>
NAME=<match aws-ecs-setup.sh value>
CONTAINER_PORT=<match aws-ecs-setup.sh value>
HOST_PORT=<match aws-ecs-setup.sh value>
```

3. Run the script:

   ```bash
   ./continuous-deploy.sh
   ```
4. The script will:

   - Build the Docker image using the latest code.
   - Push the new image to the ECR repository.
   - Update the ECS service with the new image.

---

## Example aws-ecs-deploy.sh Output

The public IP is output at the end.

```text
Creating VPC...
VPC ID: vpc-0f75e2c1c10f0a65d
Creating Subnet...
Subnet ID: subnet-022bc5238c54fabd2
Creating Internet Gateway...
Internet Gateway ID: igw-09476c73f5bde71d4
Attaching Internet Gateway to VPC...
Creating Route Table...
Route Table ID: rtb-090652a5b4b0d67ff
Creating route to Internet Gateway...
Associating Route Table with Subnet...
Modifying Subnet to assign public IPs...
Creating Security Group...
Security Group ID: sg-0f16b4598b0497dba
Authorizing inbound traffic on port 8000...
Checking if ECR repository exists...
Creating ECR repository...
ECR repository 'python-registry' created.
ECR Repository URI: 397188165174.dkr.ecr.us-west-1.amazonaws.com/python-registry
Checking if IAM role 'ecsTaskRole' exists...
IAM role 'ecsTaskRole' already exists.
Logging in to ECR...
WARNING! Your password will be stored unencrypted in /home/ola/.docker/config.json.
Configure a credential helper to remove this warning. See
https://docs.docker.com/engine/reference/commandline/login/#credentials-store

Login Succeeded
DOCKER_FILE: Dockerfile.python
CONTAINER_NAME: python-test-harness
IMAGE_TAG: f79f044
Building Docker image...
failed to fetch metadata: fork/exec /usr/local/lib/docker/cli-plugins/docker-buildx: no such file or directory

DEPRECATED: The legacy builder is deprecated and will be removed in a future release.
            Install the buildx component to build images with BuildKit:
            https://docs.docker.com/go/buildx/

Sending build context to Docker daemon  10.29kB
Step 1/17 : FROM postgres:17
17: Pulling from library/postgres
Digest: sha256:fe4efc6901dda0d952306fd962643d8022d7bb773ffe13fe8a21551b9276e50c
Status: Image is up to date for postgres:17
 ---> 810c36706d00
Step 2/17 : RUN apt-get update && apt-get install -y python3 python3-pip python3-venv procps &&     apt-get clean && rm -rf /var/lib/apt/lists/*
 ---> Using cache
 ---> 8f27c20fef3d
Step 3/17 : RUN python3 --version
 ---> Using cache
 ---> 1534400f1e3e
Step 4/17 : COPY requirements.txt .
 ---> Using cache
 ---> c56377ba3ed4
Step 5/17 : RUN python3 -m venv /app/venv
 ---> Using cache
 ---> 969ba1906d4e
Step 6/17 : RUN /app/venv/bin/python -m pip install --upgrade pip &&     /app/venv/bin/pip install --no-cache-dir -r requirements.txt
 ---> Using cache
 ---> 5d71c72d4752
Step 7/17 : ENV PATH="/app/venv/bin:$PATH"
 ---> Using cache
 ---> dd14486852ea
Step 8/17 : WORKDIR /app
 ---> Using cache
 ---> 939390dc3c97
Step 9/17 : ENV POSTGRES_USER=postgres
 ---> Using cache
 ---> 0a3b33a93008
Step 10/17 : ENV POSTGRES_PASSWORD=postgres
 ---> Using cache
 ---> 9a3a1145fb02
Step 11/17 : ENV POSTGRES_DB=users
 ---> Using cache
 ---> e3b00d298c9f
Step 12/17 : COPY . .
 ---> Using cache
 ---> 0841a5e1f589
Step 13/17 : COPY init.sql /docker-entrypoint-initdb.d/init.sql
 ---> Using cache
 ---> 8adac8a525b3
Step 14/17 : COPY entrypoint.sh /usr/local/bin/
 ---> Using cache
 ---> 08c069088b5c
Step 15/17 : RUN chmod +x /usr/local/bin/entrypoint.sh
 ---> Using cache
 ---> 2aa3173ad1c6
Step 16/17 : ENTRYPOINT ["entrypoint.sh"]
 ---> Using cache
 ---> bb81f81d0c5c
Step 17/17 : EXPOSE 8000
 ---> Using cache
 ---> 727169123bac
Successfully built 727169123bac
Successfully tagged python-test-harness:f79f044
Tagging and pushing Docker image to ECR...
The push refers to repository [397188165174.dkr.ecr.us-west-1.amazonaws.com/python-registry]
a006fab3896c: Pushed
c056e713fe88: Pushed
0a1fd053ab0f: Pushed
27d0456b65fd: Pushed
a6a285f742a1: Pushed
0a0ae44a27ef: Pushed
65f98df6b00c: Pushed
74274d92bd72: Pushed
97d0da1ce974: Pushed
0b8ece3d93b7: Pushed
f1f11505df06: Pushed
88e07dfeb8ef: Pushed
bf0c9622ebbe: Pushed
4d96fc7cd897: Pushed
7b9b519c5526: Pushed
7635ed1a550f: Pushed
9d9b007dba3e: Pushed
4759ed09c338: Pushed
5e84af0b2f05: Pushed
2ee17811b681: Pushed
37430cc3024b: Pushed
c0f1022b22a9: Pushed
f79f044: digest: sha256:df55e5f8dbaceabef7745b775fe4ec7587a6345075221d09fdcfcf12007a3260 size: 4920
Checking if ECS cluster 'python-cluster' exists...
Creating ECS cluster...
ECS cluster 'python-cluster' created.
Checking if CloudWatch log group '/ecs/python' exists...
CloudWatch log group '/ecs/python' already exists.
Registering ECS task definition...
Checking if ECS service 'python-service' exists...
Creating ECS service...
ECS service 'python-service' created.
ECS service and task created successfully.
Waiting for ECS task to start...
Task not found. Retrying in 5 seconds...
Task not found. Retrying in 5 seconds...
Task not found. Retrying in 5 seconds...
Task not found. Retrying in 5 seconds...
Task ARN found: arn:aws:ecs:us-west-1:397188165174:task/python-cluster/640ed129b6a74eebbb66add70f931e2c
Waiting for ECS task to reach RUNNING state...
Task status is 'PROVISIONING'. Retrying in 5 seconds...
Task status is 'PENDING'. Retrying in 5 seconds...
Task status is 'PENDING'. Retrying in 5 seconds...
Task status is 'PENDING'. Retrying in 5 seconds...
Task status is 'PENDING'. Retrying in 5 seconds...
Task is in RUNNING state.
Task ARN: arn:aws:ecs:us-west-1:397188165174:task/python-cluster/640ed129b6a74eebbb66add70f931e2c
ENI ID: eni-0ec329c8b17a991e3
Public IP Address of Deployed Container: 54.183.166.190
```

## Summary

1. Run `aws-ecs-setup.sh` once to set up the AWS infrastructure and deploy the application.
2. Use `continuous-deploy.sh` to build, push, and deploy updates to ECS.
