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

# Register new task definition with updated image
echo "Registering new task definition..."
NEW_TASK_DEF=$(aws ecs register-task-definition \
    --family $TASK_DEFINITION_NAME \
    --network-mode awsvpc \
    --execution-role-arn "arn:aws:iam::$ACCOUNT_ID:role/ecsTaskExecutionRole" \
    --task-role-arn "arn:aws:iam::$ACCOUNT_ID:role/ecsTaskRole" \
    --container-definitions "[
        {
            \"name\": \"$CONTAINER_NAME\",
            \"image\": \"$ECR_URI:$IMAGE_TAG\",
            \"cpu\": 256,
            \"memory\": 512,
            \"portMappings\": [
                {
                    \"containerPort\": 8000,
                    \"hostPort\": 8000,
                    \"protocol\": \"tcp\"
                }
            ],
            \"essential\": true,
            \"logConfiguration\": {
                \"logDriver\": \"awslogs\",
                \"options\": {
                    \"awslogs-group\": \"/ecs/$NAME\",
                    \"awslogs-region\": \"$REGION\",
                    \"awslogs-stream-prefix\": \"ecs\"
                }
            }
        }
    ]" \
    --requires-compatibilities FARGATE \
    --cpu "1024" \
    --memory "2048" \
    --region $REGION)

TASK_DEFINITION_REVISION=$(echo $NEW_TASK_DEF | jq -r '.taskDefinition.taskDefinitionArn')
echo "New task definition registered: $TASK_DEFINITION_REVISION"

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