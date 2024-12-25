#!/bin/bash

# Set variables
LANGUAGE="python"
DOCKER_FILE="Dockerfile.python"
REGION="us-west-1"
NAME="python"
ECR_REPO_NAME="$NAME-registry"
CONTAINER_NAME="$NAME-test-harness"
IMAGE_TAG=$(git rev-parse --short HEAD)

# Get AWS Account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Get ECR Repository URI
ECR_URI=$(aws ecr describe-repositories --repository-names $ECR_REPO_NAME \
--region $REGION --query 'repositories[0].repositoryUri' --output text)

# Log in to ECR
echo "Logging in to ECR..."
aws ecr get-login-password --region $REGION | \
docker login --username AWS --password-stdin $ECR_URI

# Build Docker image
echo "Building Docker image..."
docker build --pull --rm -f "$DOCKER_FILE" -t $CONTAINER_NAME:$IMAGE_TAG ./$LANGUAGE

# Tag and push Docker image to ECR
echo "Tagging and pushing Docker image to ECR..."
docker tag $CONTAINER_NAME:$IMAGE_TAG $ECR_URI:$IMAGE_TAG
docker push $ECR_URI:$IMAGE_TAG

# Update ECS service with new task definition
SERVICE_NAME="$NAME-service"
CLUSTER_NAME="$NAME-cluster"
TASK_DEFINITION_NAME="$NAME-task"

echo "Updating ECS service with new image..."
aws ecs update-service \
    --cluster $CLUSTER_NAME \
    --service $SERVICE_NAME \
    --force-new-deployment \
    --region $REGION > /dev/null

echo "ECS service updated successfully with new image."