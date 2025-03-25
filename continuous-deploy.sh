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

# Set variables
LANGUAGE="net"
DOCKER_FILE="Dockerfile.node"
REGION="us-west-2"
NAME="node"
CONTAINER_PORT=5000
HOST_PORT=5000

CLUSTER_NAME="$NAME-cluster"
SERVICE_NAME="$NAME-service"
TASK_DEFINITION_NAME="$NAME-task"
ECR_REPO_NAME="$NAME-repository"
CONTAINER_NAME="$NAME-test-harness"
LOG_GROUP_NAME="/ecs/$NAME"

# Get AWS Account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Use Git commit hash as IMAGE_TAG
IMAGE_TAG=$(git rev-parse --short HEAD)

# Get ECR Repository URI
ECR_URI=$(aws ecr describe-repositories --repository-names $ECR_REPO_NAME \
--region $REGION --query 'repositories[0].repositoryUri' --output text)

if [ -z "$ECR_URI" ]; then
    echo "Error: Failed to retrieve ECR repository URI for $ECR_REPO_NAME."
    exit 1
fi

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

# Register a new ECS task definition
echo "Registering new ECS task definition..."
TASK_DEF_JSON=$(cat <<EOF
{
    "family": "$TASK_DEFINITION_NAME",
    "taskRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/ecsTaskRole",
    "executionRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/ecsTaskExecutionRole",
    "containerDefinitions": [
        {
            "name": "$CONTAINER_NAME",
            "image": "$ECR_URI:$IMAGE_TAG",
            "cpu": 1024,
            "memory": 2048,
            "portMappings": [
                {
                    "containerPort": $CONTAINER_PORT,
                    "hostPort": $HOST_PORT,
                    "protocol": "tcp"
                }
            ],
            "essential": true,
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "$LOG_GROUP_NAME",
                    "awslogs-region": "$REGION",
                    "awslogs-stream-prefix": "ecs"
                }
            }
        }
    ],
    "requiresCompatibilities": [
        "FARGATE"
    ],
    "cpu": "1024",
    "memory": "2048",
    "networkMode": "awsvpc",
    "runtimePlatform": {
        "cpuArchitecture": "X86_64",
        "operatingSystemFamily": "LINUX"
    }
}
EOF
)

echo "$TASK_DEF_JSON" > task_definition.json
NEW_TASK_DEF=$(aws ecs register-task-definition --cli-input-json file://task_definition.json --output json \
--region $REGION)

# Extract task definition ARN
TASK_DEFINITION_REVISION=$(echo $NEW_TASK_DEF | jq -r '.taskDefinition.taskDefinitionArn')

# Validate task definition registration
if [ -z "$TASK_DEFINITION_REVISION" ]; then
    echo "Error: Task definition registration failed. No task definition ARN returned."
    exit 1
fi

echo "New task definition registered: $TASK_DEFINITION_REVISION"

# Update ECS service with the new task definition
echo "Updating ECS service with new task definition..."
aws ecs update-service \
    --cluster $CLUSTER_NAME \
    --service $SERVICE_NAME \
    --task-definition $TASK_DEFINITION_REVISION \
    --force-new-deployment \
    --region $REGION > /dev/null

echo "Waiting for ECS service to stabilize..."
MAX_ATTEMPTS=60
ATTEMPT=0

# Wait for the service to stabilize
while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do
    SERVICE_STATUS=$(aws ecs describe-services \
        --cluster $CLUSTER_NAME \
        --services $SERVICE_NAME \
        --region $REGION \
        --query "services[0].deployments[0].rolloutState" \
        --output text)

    if [ "$SERVICE_STATUS" == "COMPLETED" ]; then
        echo "ECS service has stabilized."
        break
    fi

    echo "Service status is '$SERVICE_STATUS'. Retrying in 5 seconds..."
    sleep 5
    ATTEMPT=$((ATTEMPT + 1))
done

if [ "$SERVICE_STATUS" != "COMPLETED" ]; then
    echo "Error: ECS service did not stabilize after 5 minutes."
    exit 1
fi

# Retrieve task ARN
echo "Retrieving task ARN..."
TASK_ARN=$(aws ecs list-tasks \
    --cluster $CLUSTER_NAME \
    --service-name $SERVICE_NAME \
    --region $REGION \
    --query "taskArns[0]" \
    --output text)

if [ -z "$TASK_ARN" ] || [ "$TASK_ARN" == "None" ]; then
    echo "Error: No task found for service $SERVICE_NAME in cluster $CLUSTER_NAME."
    exit 1
fi

echo "Task ARN: $TASK_ARN"

# Retrieve ENI ID
ENI_ID=$(aws ecs describe-tasks \
    --cluster $CLUSTER_NAME \
    --tasks $TASK_ARN \
    --region $REGION \
    --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" \
    --output text)

if [ -z "$ENI_ID" ] || [ "$ENI_ID" == "None" ]; then
    echo "Error: No ENI found for task $TASK_ARN."
    exit 1
fi

echo "ENI ID: $ENI_ID"

# Retrieve Public IP
PUBLIC_IP=$(aws ec2 describe-network-interfaces \
    --network-interface-ids $ENI_ID \
    --region $REGION \
    --query "NetworkInterfaces[0].Association.PublicIp" \
    --output text)

if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" == "None" ]; then
    echo "Error: No public IP associated with ENI $ENI_ID."
    exit 1
fi

echo "Public IP Address of Deployed Container: $PUBLIC_IP"