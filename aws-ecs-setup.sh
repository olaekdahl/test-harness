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

# Run this script once to setup the initial AWS infrastructure

# Set variables

# python, net, java, or node
LANGUAGE="net"
DOCKER_FILE="Dockerfile.net"
REGION="us-west-1"
NAME="net"
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

# Create VPC
echo "Creating VPC..."
VPC_JSON=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
--tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$NAME-vpc}]" \
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
SUBNET_ID_1=$(echo $SUBNET_JSON | jq -r '.Subnet.SubnetId')
echo "Subnet ID: $SUBNET_ID_1"

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
--subnet-id $SUBNET_ID_1 --region $REGION > /dev/null

# Modify Subnet to assign public IPs
echo "Modifying Subnet to assign public IPs..."
aws ec2 modify-subnet-attribute --subnet-id $SUBNET_ID_1 \
--map-public-ip-on-launch --region $REGION

# Create Security Group
echo "Creating Security Group..."
SECURITY_GROUP_JSON=$(aws ec2 create-security-group --group-name edp-sg \
--description "EDP Security Group" --vpc-id $VPC_ID \
--region $REGION --output json)
SECURITY_GROUP_ID=$(echo $SECURITY_GROUP_JSON | jq -r '.GroupId')
echo "Security Group ID: $SECURITY_GROUP_ID"

# Authorize inbound traffic on port $HOST_PORT
echo "Authorizing inbound traffic on port $HOST_PORT..."
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID \
--protocol tcp --port $HOST_PORT --cidr 0.0.0.0/0 --region $REGION > /dev/null

# Create ECR repository if it doesn't exist
echo "Checking if ECR repository exists..."
ECR_REPO_CHECK=$(aws ecr describe-repositories --repository-names $ECR_REPO_NAME \
--region $REGION --output text 2>/dev/null)

if [ -z "$ECR_REPO_CHECK" ]; then
    echo "Creating ECR repository..."
    aws ecr create-repository --repository-name $ECR_REPO_NAME \
    --region $REGION > /dev/null
    echo "ECR repository '$ECR_REPO_NAME' created."
else
    echo "ECR repository '$ECR_REPO_NAME' already exists."
fi

# Get ECR repository URI
ECR_URI=$(aws ecr describe-repositories --repository-names $ECR_REPO_NAME \
--region $REGION --query 'repositories[0].repositoryUri' --output text)
echo "ECR Repository URI: $ECR_URI"


ROLE_NAME="ecsTaskRole"
EXECUTION_ROLE_NAME="ecsExecutionRole"

# Create IAM role for ECS task if it doesn't exist
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

# Log in to ECR
echo "Logging in to ECR..."
aws ecr get-login-password --region $REGION | \
docker login --username AWS --password-stdin $ECR_URI

# Build Docker image
echo "DOCKER_FILE: $DOCKER_FILE"
echo "CONTAINER_NAME: $CONTAINER_NAME"
echo "IMAGE_TAG: $IMAGE_TAG"
echo "Building Docker image..."
docker build --pull --rm -f "$DOCKER_FILE" -t $CONTAINER_NAME:$IMAGE_TAG ./$LANGUAGE

# Tag and push Docker image to ECR
echo "Tagging and pushing Docker image to ECR..."
docker tag $CONTAINER_NAME:$IMAGE_TAG $ECR_URI:$IMAGE_TAG
docker push $ECR_URI:$IMAGE_TAG

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

# Create CloudWatch log group if it doesn't exist
echo "Checking if CloudWatch log group '$LOG_GROUP_NAME' exists..."
LOG_GROUP_CHECK=$(aws logs describe-log-groups --log-group-name-prefix $LOG_GROUP_NAME \
--region $REGION --output text --query 'logGroups[0].logGroupName' 2>/dev/null)

if [ -z "$LOG_GROUP_CHECK" ] || [ "$LOG_GROUP_CHECK" == "None" ]; then
    echo "Creating CloudWatch log group..."
    aws logs create-log-group --log-group-name $LOG_GROUP_NAME \
    --region $REGION > /dev/null
    echo "CloudWatch log group '$LOG_GROUP_NAME' created."
else
    echo "CloudWatch log group '$LOG_GROUP_NAME' already exists."
fi

# Register ECS task definition
echo "Registering ECS task definition..."
TASK_DEF_JSON=$(cat <<EOF
{
    "family": "$TASK_DEFINITION_NAME",
    "taskRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME",
    "executionRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/$EXECUTION_ROLE_NAME",
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
            "healthCheck": {
                "retries": 3,
                "command": [
                    "CMD-SHELL",
                    "curl -f http://127.0.0.1:$HOST_PORT/api/health || exit 1"
                ],
                "timeout": 5,
                "interval": 30,
                "startPeriod": 300
            },
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

echo "$TASK_DEF_JSON" > task-definition.json
aws ecs register-task-definition --cli-input-json file://task-definition.json \
--region $REGION > /dev/null

# Create ECS service if it doesn't exist
echo "Checking if ECS service '$SERVICE_NAME' exists..."
SERVICE_CHECK=$(aws ecs describe-services --cluster $CLUSTER_NAME \
--services $SERVICE_NAME --region $REGION \
--output text --query 'services[0].status' 2>/dev/null)

if [ "$SERVICE_CHECK" != "ACTIVE" ]; then
    echo "Creating ECS service..."
    aws ecs create-service \
        --cluster $CLUSTER_NAME \
        --service-name $SERVICE_NAME \
        --task-definition $TASK_DEFINITION_NAME \
        --desired-count 1 \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID_1],securityGroups=[$SECURITY_GROUP_ID],assignPublicIp=ENABLED}" \
        --region $REGION > /dev/null
    echo "ECS service '$SERVICE_NAME' created."
else
    echo "ECS service '$SERVICE_NAME' already exists."
    # Update the service with the new task definition
    echo "Updating ECS service with new task definition..."
    aws ecs update-service \
        --cluster $CLUSTER_NAME \
        --service $SERVICE_NAME \
        --task-definition $TASK_DEFINITION_NAME \
        --region $REGION > /dev/null
    echo "ECS service '$SERVICE_NAME' updated."
fi

echo "ECS service and task created successfully."

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

echo "Task ARN: $TASK_ARN"

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

echo "Public IP Address of Deployed Container: $PUBLIC_IP"
echo "Health Endpoint: http://$PUBLIC_IP:$HOST_PORT/api/health"