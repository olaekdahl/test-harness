#!/bin/bash

cat << "EOF"
  ______ _____  _____   _______ ______  _____ _______   _    _          _____  _   _ ______  _____ _____ 
 |  ____/ ____|/ ____| |__   __|  ____|/ ____|__   __| | |  | |   /\   |  __ \| \ | |  ____|/ ____/ ____|
 | |__ | |    | (___      | |  | |__  | (___    | |    | |__| |  /  \  | |__) |  \| | |__  | (___| (___  
 |  __|| |     \___ \     | |  |  __|  \___ \   | |    |  __  | / /\ \ |  _  /| . ` |  __|  \___ \\___ \ 
 | |___| |____ ____) |    | |  | |____ ____) |  | |    | |  | |/ ____ \| | \ \| |\  | |____ ____) |___) |
 |______\_____|_____/     |_|  |______|_____/   |_|    |_|  |_/_/    \_\_|  \_\_| \_|______|_____/_____/
EOF

printf "\n\n"

REGION="us-west-1"

# ECS/Service names
CLUSTER_NAME="ecs-cluster"
SERVICE_NAME="ecs-service"
TASK_DEFINITION_NAME="ecs-task"

# ECR repository names
POSTGRES_ECR_REPO_NAME="postgres"
API_ECR_REPO_NAME="api"
UI_ECR_REPO_NAME="ui"

# Container names, images, and ports (as used in the ECS task definition)
POSTGRES_CONTAINER_NAME="postgres"
API_CONTAINER_NAME="api"
UI_CONTAINER_NAME="ui"
POSTGRES_PORT=5432
API_PORT=8080
UI_PORT=80

# AWS Account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Use Git commit hash as IMAGE_TAG (adjust if needed)
IMAGE_TAG=$(git rev-parse --short HEAD 2>/dev/null || echo "latest")

# CloudWatch Logs
LOG_GROUP_NAME="/ecs/$TASK_DEFINITION_NAME"


# Get the Target Group ARN from the ECS Service
TG_ARN=$(aws ecs describe-services \
  --cluster "$CLUSTER_NAME" \
  --services "$SERVICE_NAME" \
  --region "$REGION" \
  --query "services[0].loadBalancers[0].targetGroupArn" \
  --output text)

if [ -z "$TG_ARN" ] || [ "$TG_ARN" == "None" ]; then
  echo "Error: Could not retrieve Target Group ARN from service '$SERVICE_NAME'."
  exit 1
fi

echo "Found Target Group ARN: $TG_ARN"

# From the Target Group, retrieve the Load Balancer ARN
LB_ARN=$(aws elbv2 describe-target-groups \
  --target-group-arns "$TG_ARN" \
  --region "$REGION" \
  --query "TargetGroups[0].LoadBalancerArns[0]" \
  --output text)

if [ -z "$LB_ARN" ] || [ "$LB_ARN" == "None" ]; then
  echo "Error: Could not retrieve Load Balancer ARN from Target Group '$TG_ARN'."
  exit 1
fi

echo "Found Load Balancer ARN: $LB_ARN"

# From the Load Balancer ARN, retrieve the DNS name
ALB_DNS_NAME=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$LB_ARN" \
  --region "$REGION" \
  --query "LoadBalancers[0].DNSName" \
  --output text)

if [ -z "$ALB_DNS_NAME" ] || [ "$ALB_DNS_NAME" == "None" ]; then
  echo "Error: Could not retrieve DNS name for ALB '$LB_ARN'."
  exit 1
fi

echo "Found ALB DNS Name: $ALB_DNS_NAME"

echo "Retrieving ECR URIs..."
POSTGRES_ECR_URI=$(aws ecr describe-repositories --repository-names $POSTGRES_ECR_REPO_NAME \
  --region $REGION --query 'repositories[0].repositoryUri' --output text 2>/dev/null \
  || aws ecr create-repository --repository-name $POSTGRES_ECR_REPO_NAME --region $REGION \
    --query 'repository.repositoryUri' --output text)

API_ECR_URI=$(aws ecr describe-repositories --repository-names $API_ECR_REPO_NAME \
  --region $REGION --query 'repositories[0].repositoryUri' --output text 2>/dev/null \
  || aws ecr create-repository --repository-name $API_ECR_REPO_NAME --region $REGION \
    --query 'repository.repositoryUri' --output text)

UI_ECR_URI=$(aws ecr describe-repositories --repository-names $UI_ECR_REPO_NAME \
  --region $REGION --query 'repositories[0].repositoryUri' --output text 2>/dev/null \
  || aws ecr create-repository --repository-name $UI_ECR_REPO_NAME --region $REGION \
    --query 'repository.repositoryUri' --output text)

if [ -z "$POSTGRES_ECR_URI" ] || [ -z "$API_ECR_URI" ] || [ -z "$UI_ECR_URI" ]; then
    echo "Error: Could not determine ECR repository URIs."
    exit 1
fi

echo "Logging in to ECR..."
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin "$POSTGRES_ECR_URI"
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin "$API_ECR_URI"
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin "$UI_ECR_URI"


# Build, Tag, and Push each container image 
# Copy init.sql to a temporary build context for Postgres
echo "Preparing Postgres init script..."
TEMP_DIR=$(mktemp -d)
cp ./docker/postgres/init.sql $TEMP_DIR/
cat > $TEMP_DIR/Dockerfile <<EOF
FROM $POSTGRES_IMAGE
COPY init.sql /docker-entrypoint-initdb.d/
EOF

docker build -t postgres-init $TEMP_DIR
docker tag postgres-init:latest $ECR_URI:$IMAGE_TAG
docker push "$POSTGRES_ECR_URI:$IMAGE_TAG"
rm -rf $TEMP_DIR

echo "Building, tagging, and pushing API image..."
docker build -t api:latest ./docker/api
docker tag api:latest "$API_ECR_URI:$IMAGE_TAG"
docker push "$API_ECR_URI:$IMAGE_TAG"

echo "Building, tagging, and pushing UI image..."
docker build --build-arg VITE_API_URL=http://$ALB_DNS_NAME:$API_PORT -t ui ./docker/ui
docker tag ui:latest "$UI_ECR_URI:$IMAGE_TAG"
docker push "$UI_ECR_URI:$IMAGE_TAG"

# Register new ECS Task Definition (with updated image tags)
echo "Registering new ECS task definition..."

# Create a JSON file on-the-fly
cat > task_definition.json <<EOF
{
    "family": "$TASK_DEFINITION_NAME",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "1024",
    "memory": "2048",
    "networkMode": "awsvpc",
    "taskRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/ecsTaskRole",
    "executionRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/ecsExecutionRole",
    "containerDefinitions": [
        {
            "name": "$POSTGRES_CONTAINER_NAME",
            "image": "$POSTGRES_ECR_URI:$IMAGE_TAG",
            "portMappings": [
                {
                    "containerPort": $POSTGRES_PORT,
                    "hostPort": $POSTGRES_PORT
                }
            ],
            "essential": true,
            "environment": [
                {"name": "POSTGRES_USER", "value": "postgres"},
                {"name": "POSTGRES_PASSWORD", "value": "postgres"},
                {"name": "POSTGRES_DB", "value": "users"}
            ],
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "$LOG_GROUP_NAME",
                    "awslogs-region": "$REGION",
                    "awslogs-stream-prefix": "postgres"
                }
            }
        },
        {
            "name": "$API_CONTAINER_NAME",
            "image": "$API_ECR_URI:$IMAGE_TAG",
            "portMappings": [
                {
                    "containerPort": $API_PORT,
                    "hostPort": $API_PORT
                }
            ],
            "essential": true,
            "dependsOn": [
                {
                    "containerName": "$POSTGRES_CONTAINER_NAME",
                    "condition": "START"
                }
            ],
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "$LOG_GROUP_NAME",
                    "awslogs-region": "$REGION",
                    "awslogs-stream-prefix": "api"
                }
            }
        },
        {
            "name": "$UI_CONTAINER_NAME",
            "image": "$UI_ECR_URI:$IMAGE_TAG",
            "portMappings": [
                {
                    "containerPort": $UI_PORT,
                    "hostPort": $UI_PORT
                }
            ],
            "essential": true,
            "dependsOn": [
                {
                    "containerName": "$API_CONTAINER_NAME",
                    "condition": "START"
                }
            ],
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "$LOG_GROUP_NAME",
                    "awslogs-region": "$REGION",
                    "awslogs-stream-prefix": "ui"
                }
            }
        }
    ]
}
EOF

NEW_TASK_DEF_JSON=$(aws ecs register-task-definition \
  --cli-input-json file://task_definition.json \
  --region "$REGION" \
  --output json)

NEW_TASK_DEF_ARN=$(echo "$NEW_TASK_DEF_JSON" | jq -r '.taskDefinition.taskDefinitionArn')

if [ -z "$NEW_TASK_DEF_ARN" ] || [ "$NEW_TASK_DEF_ARN" == "null" ]; then
    echo "Error: Failed to register new task definition."
    exit 1
fi

echo "Successfully registered new task definition: $NEW_TASK_DEF_ARN"

# Update the ECS Service to use the new Task Definition
echo "Updating ECS service ($SERVICE_NAME) to use new task definition..."

aws ecs update-service \
  --cluster "$CLUSTER_NAME" \
  --service "$SERVICE_NAME" \
  --task-definition "$NEW_TASK_DEF_ARN" \
  --force-new-deployment \
  --region "$REGION" > /dev/null

# Wait for the ECS Service to stabilize
echo "Waiting for ECS service to stabilize..."

MAX_ATTEMPTS=60
ATTEMPT=0
SLEEP_TIME=5

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    DEPLOYMENT_STATUS=$(aws ecs describe-services \
      --cluster "$CLUSTER_NAME" \
      --services "$SERVICE_NAME" \
      --region "$REGION" \
      --query "services[0].deployments[0].rolloutState" \
      --output text 2>/dev/null)

    if [ "$DEPLOYMENT_STATUS" == "COMPLETED" ]; then
        echo "ECS service has stabilized."
        break
    fi

    echo "Current rollout state: $DEPLOYMENT_STATUS. Retrying in $SLEEP_TIME seconds..."
    sleep $SLEEP_TIME
    ((ATTEMPT++))
done

if [ "$DEPLOYMENT_STATUS" != "COMPLETED" ]; then
    echo "Error: ECS service did not stabilize after $((MAX_ATTEMPTS * SLEEP_TIME / 60)) minutes."
    exit 1
fi

# Retrieve Public IP 
echo "Retrieving task ARN..."
TASK_ARN=$(aws ecs list-tasks \
  --cluster "$CLUSTER_NAME" \
  --service-name "$SERVICE_NAME" \
  --region "$REGION" \
  --query "taskArns[0]" --output text)

if [ -z "$TASK_ARN" ] || [ "$TASK_ARN" == "None" ]; then
    echo "Error: No task found for service $SERVICE_NAME in cluster $CLUSTER_NAME."
    exit 1
fi

echo "Task ARN: $TASK_ARN"

ENI_ID=$(aws ecs describe-tasks \
  --cluster "$CLUSTER_NAME" \
  --tasks "$TASK_ARN" \
  --region "$REGION" \
  --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" --output text)

if [ -z "$ENI_ID" ] || [ "$ENI_ID" == "None" ]; then
    echo "Error: No ENI found for task $TASK_ARN."
    exit 1
fi

echo "ENI ID: $ENI_ID"

PUBLIC_IP=$(aws ec2 describe-network-interfaces \
  --network-interface-ids "$ENI_ID" \
  --region "$REGION" \
  --query "NetworkInterfaces[0].Association.PublicIp" --output text)

if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" == "None" ]; then
    echo "Warning: No public IP associated with the ENI ($ENI_ID)."
    echo "If this is a private service, you can access it via the ALB DNS or VPC IP."
else
    echo "Public IP Address of one running task: $PUBLIC_IP"
fi

echo "Deployment complete!"
echo "New Task Definition: $NEW_TASK_DEF_ARN"
echo "If you have an Application Load Balancer, use its DNS name to reach your UI or API."