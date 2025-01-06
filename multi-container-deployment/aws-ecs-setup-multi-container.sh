#!/bin/bash

set -e

# Configuration Variables
REGION="us-west-1"
CLUSTER_NAME="ecs-cluster"
SERVICE_NAME="ecs-service"
TASK_DEFINITION_NAME="ecs-task"
POSTGRES_IMAGE="postgres:17"
API_IMAGE="api:latest"
UI_IMAGE="ui:latest"
POSTGRES_PORT=5432
API_PORT=8080
UI_PORT=80

# AWS Account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Use Git commit hash as IMAGE_TAG
IMAGE_TAG=$(git rev-parse --short HEAD)

# Create VPC
echo "Creating VPC..."
VPC_JSON=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
--tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=ecs-vpc}]" \
--region $REGION --output json)
VPC_ID=$(echo $VPC_JSON | jq -r '.Vpc.VpcId')
echo "VPC ID: $VPC_ID"

# Enable DNS support and hostnames
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support "{\"Value\":true}" --region $REGION
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames "{\"Value\":true}" --region $REGION

# Create Subnet
echo "Creating Subnet..."
SUBNET_JSON=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 \
--region $REGION --output json)
SUBNET_ID=$(echo $SUBNET_JSON | jq -r '.Subnet.SubnetId')
echo "Subnet ID: $SUBNET_ID"

# Create Internet Gateway
echo "Creating Internet Gateway..."
IGW_JSON=$(aws ec2 create-internet-gateway --region $REGION --output json)
IGW_ID=$(echo $IGW_JSON | jq -r '.InternetGateway.InternetGatewayId')
echo "Internet Gateway ID: $IGW_ID"

# Attach Internet Gateway to VPC
echo "Attaching Internet Gateway to VPC..."
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID --region $REGION

# Create Route Table
echo "Creating Route Table..."
ROUTE_TABLE_JSON=$(aws ec2 create-route-table --vpc-id $VPC_ID \
--region $REGION --output json)
ROUTE_TABLE_ID=$(echo $ROUTE_TABLE_JSON | jq -r '.RouteTable.RouteTableId')
echo "Route Table ID: $ROUTE_TABLE_ID"

# Create Route to Internet Gateway
echo "Creating route to Internet Gateway..."
aws ec2 create-route --route-table-id $ROUTE_TABLE_ID \
--destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID \
--region $REGION > /dev/null

# Associate Route Table with Subnet
echo "Associating Route Table with Subnet..."
aws ec2 associate-route-table --route-table-id $ROUTE_TABLE_ID \
--subnet-id $SUBNET_ID --region $REGION > /dev/null

# Modify Subnet to assign public IPs
echo "Modifying Subnet to assign public IPs..."
aws ec2 modify-subnet-attribute --subnet-id $SUBNET_ID \
--map-public-ip-on-launch --region $REGION

# Create Security Group
echo "Creating Security Group..."
SECURITY_GROUP_JSON=$(aws ec2 create-security-group --group-name ecs-sg \
--description "ECS Security Group" --vpc-id $VPC_ID \
--region $REGION --output json)
SECURITY_GROUP_ID=$(echo $SECURITY_GROUP_JSON | jq -r '.GroupId')
echo "Security Group ID: $SECURITY_GROUP_ID"

# Authorize inbound traffic on all necessary ports
echo "Authorizing inbound traffic..."
for PORT in $POSTGRES_PORT $API_PORT $UI_PORT; do
    aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID \
    --protocol tcp --port $PORT --cidr 0.0.0.0/0 --region $REGION > /dev/null
done

# Create IAM roles for ECS tasks
ROLE_NAME="ecsTaskRole"
EXECUTION_ROLE_NAME="ecsExecutionRole"

# Create Task Role if not exists
echo "Checking if IAM role '$ROLE_NAME' exists..."
ROLE_CHECK=$(aws iam get-role --role-name $ROLE_NAME --region $REGION --output text 2>/dev/null)
if [ -z "$ROLE_CHECK" ]; then
    echo "Creating IAM role '$ROLE_NAME' for ECS task..."
    TRUST_POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ecs-tasks.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF
)
    aws iam create-role --role-name $ROLE_NAME \
        --assume-role-policy-document file://<(echo "$TRUST_POLICY") \
        --region $REGION > /dev/null
    echo "IAM role '$ROLE_NAME' created."
else
    echo "IAM role '$ROLE_NAME' already exists."
fi

# Create Execution Role if not exists
echo "Checking if IAM role '$EXECUTION_ROLE_NAME' exists..."
if ! aws iam get-role --role-name $EXECUTION_ROLE_NAME --region $REGION --output text 2>/dev/null; then
    echo "Creating IAM execution role '$EXECUTION_ROLE_NAME' for ECS task..."
    TRUST_POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ecs-tasks.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF
)
    aws iam create-role --role-name $EXECUTION_ROLE_NAME \
        --assume-role-policy-document file://<(echo "$TRUST_POLICY") \
        --region $REGION > /dev/null
    echo "IAM execution role '$EXECUTION_ROLE_NAME' created."
else
    echo "IAM execution role '$EXECUTION_ROLE_NAME' already exists."
fi

# Attach Policies to Roles
echo "Attaching ECS task execution role policy..."
aws iam attach-role-policy --role-name $EXECUTION_ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy \
    --region $REGION > /dev/null

# Build and Push Docker Images
echo "Building and Pushing Docker Images..."
for SERVICE in "api" "ui"; do
    echo "Building $SERVICE image..."
    docker build -t $SERVICE ./docker/$SERVICE
    ECR_URI=$(aws ecr describe-repositories --repository-names $SERVICE --region $REGION --query "repositories[0].repositoryUri" --output text 2>/dev/null || aws ecr create-repository --repository-name $SERVICE --region $REGION --query "repository.repositoryUri" --output text)
    echo "Pushing $SERVICE image to $ECR_URI..."
    docker tag $SERVICE:latest $ECR_URI:$IMAGE_TAG
    aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_URI
    docker push $ECR_URI:$IMAGE_TAG
done

# Copy init.sql to a temporary build context for Postgres
echo "Preparing Postgres init script..."
TEMP_DIR=$(mktemp -d)
cp ./docker/postgres/init.sql $TEMP_DIR/
cat > $TEMP_DIR/Dockerfile <<EOF
FROM $POSTGRES_IMAGE
COPY init.sql /docker-entrypoint-initdb.d/
EOF

docker build -t postgres-init $TEMP_DIR
ECR_URI=$(aws ecr describe-repositories --repository-names postgres --region $REGION --query "repositories[0].repositoryUri" --output text 2>/dev/null || aws ecr create-repository --repository-name postgres --region $REGION --query "repository.repositoryUri" --output text)
echo "Pushing Postgres image with init script to $ECR_URI..."
docker tag postgres-init:latest $ECR_URI:$IMAGE_TAG
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_URI
docker push $ECR_URI:$IMAGE_TAG
rm -rf $TEMP_DIR

# Create ECS cluster if it doesn't exist
echo "Checking if ECS cluster '$CLUSTER_NAME' exists..."
CLUSTER_CHECK=$(aws ecs describe-clusters --clusters $CLUSTER_NAME \
--region $REGION --output text --query 'clusters[0].status' 2>/dev/null)

if [ "$CLUSTER_CHECK" != "ACTIVE" ]; then
    echo "Creating ECS cluster..."
    aws ecs create-cluster --cluster-name $CLUSTER_NAME \
    --region $REGION > /dev/null
    echo "ECS cluster '$CLUSTER_NAME' created."
else
    echo "ECS cluster '$CLUSTER_NAME' already exists."
fi

# Task Definition JSON
echo "Registering ECS Task Definition..."
cat > task-definition.json <<EOF
{
    "family": "$TASK_DEFINITION_NAME",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "2048",
    "memory": "4096",
    "networkMode": "awsvpc",
    "taskRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME",
    "executionRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/$EXECUTION_ROLE_NAME",
    "containerDefinitions": [
        {
            "name": "postgres",
            "image": "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/postgres:$IMAGE_TAG",
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
            ]
        },
        {
            "name": "api",
            "image": "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/api:$IMAGE_TAG",
            "portMappings": [
                {
                    "containerPort": $API_PORT,
                    "hostPort": $API_PORT
                }
            ],
            "essential": true,
            "dependsOn": [
                {"containerName": "postgres", "condition": "START"}
            ]
        },
        {
            "name": "ui",
            "image": "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/ui:$IMAGE_TAG",
            "portMappings": [
                {
                    "containerPort": $UI_PORT,
                    "hostPort": $UI_PORT
                }
            ],
            "essential": true,
            "environment": [
                {"name": "VITE_API_URL", "value": "http://api:$API_PORT"}
            ],
            "dependsOn": [
                {"containerName": "api", "condition": "START"}
            ]
        }
    ]
}
EOF
aws ecs register-task-definition --cli-input-json file://task-definition.json --region $REGION > /dev/null

# Create ECS Service
echo "Creating ECS Service..."
aws ecs create-service \
    --cluster $CLUSTER_NAME \
    --service-name $SERVICE_NAME \
    --task-definition $TASK_DEFINITION_NAME \
    --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID],securityGroups=[$SECURITY_GROUP_ID],assignPublicIp=ENABLED}" \
    --region $REGION > /dev/null

# Output Service Information
echo "Deployment Complete."

# Get the Public IP for the UI Service
echo "Waiting for ECS task to start..."
MAX_ATTEMPTS=60
ATTEMPT=0
DELAY=5

while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do
    TASK_ARN=$(aws ecs list-tasks --cluster $CLUSTER_NAME \
        --service-name $SERVICE_NAME \
        --region $REGION \
        --query "taskArns[0]" --output text)

    if [ "$TASK_ARN" != "None" ] && [ -n "$TASK_ARN" ]; then
        echo "Task ARN found: $TASK_ARN"
        break
    fi

    echo "Task not found. Retrying in $DELAY seconds..."
    sleep $DELAY
    ATTEMPT=$((ATTEMPT + 1))
done

if [ -z "$TASK_ARN" ] || [ "$TASK_ARN" == "None" ]; then
    echo "Error: No task found for service $SERVICE_NAME in cluster $CLUSTER_NAME after 5 minutes."
    exit 1
fi

# Wait for the task to reach RUNNING state
echo "Waiting for ECS task to reach RUNNING state..."

MAX_ATTEMPTS=60  # 5 minutes (60 attempts * 5 seconds)
ATTEMPT=0
DELAY=5

while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do
    TASK_STATUS=$(aws ecs describe-tasks --cluster $CLUSTER_NAME \
        --tasks $TASK_ARN \
        --region $REGION \
        --query "tasks[0].lastStatus" --output text)

    if [ "$TASK_STATUS" == "RUNNING" ]; then
        echo "Task is in RUNNING state."
        break
    fi

    echo "Task status is '$TASK_STATUS'. Retrying in $DELAY seconds..."
    sleep $DELAY
    ATTEMPT=$((ATTEMPT + 1))
done

if [ "$TASK_STATUS" != "RUNNING" ]; then
    echo "Error: Task did not reach RUNNING state after 5 minutes."
    exit 1
fi

# Get the ENI attached to the task
ENI_ID=$(aws ecs describe-tasks --cluster $CLUSTER_NAME \
    --tasks $TASK_ARN \
    --region $REGION \
    --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" --output text)

if [ "$ENI_ID" == "None" ] || [ -z "$ENI_ID" ]; then
    echo "Error: No ENI found for task $TASK_ARN."
    exit 1
fi

echo "ENI ID: $ENI_ID"

# Get the public IP address of the ENI
PUBLIC_IP=$(aws ec2 describe-network-interfaces --network-interface-ids $ENI_ID \
    --region $REGION \
    --query "NetworkInterfaces[0].Association.PublicIp" --output text)

if [ "$PUBLIC_IP" == "None" ] || [ -z "$PUBLIC_IP" ]; then
    echo "Error: No public IP associated with ENI $ENI_ID."
    exit 1
fi

echo "Public IP Address of UI Service: $PUBLIC_IP"
echo "UI Endpoint: http://$PUBLIC_IP:$UI_PORT"