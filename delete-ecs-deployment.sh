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

# Set AWS Region
REGION="us-west-1"

# List ECS Clusters
echo "Fetching ECS clusters in region $REGION..."
CLUSTERS=$(aws ecs list-clusters --region $REGION --query "clusterArns[]" --output text)

if [ -z "$CLUSTERS" ]; then
    echo "No ECS clusters found in region $REGION."
    exit 0
fi

echo "ECS Clusters:"
i=1
declare -A CLUSTER_MAP
for CLUSTER in $CLUSTERS; do
    echo "$i. $CLUSTER"
    CLUSTER_MAP[$i]=$CLUSTER
    i=$((i + 1))
done

# Get Cluster Selection
echo ""
read -p "Enter the number of the ECS cluster to view details or delete: " CLUSTER_SELECTION
SELECTED_CLUSTER=${CLUSTER_MAP[$CLUSTER_SELECTION]}

if [ -z "$SELECTED_CLUSTER" ]; then
    echo "Invalid selection. Exiting."
    exit 1
fi

echo "Selected Cluster: $SELECTED_CLUSTER"

# Fetch VPC ID Associated with the ECS Cluster
echo "Determining VPC used by the ECS cluster..."
SUBNET_ID=$(aws ecs describe-services \
    --cluster $SELECTED_CLUSTER \
    --services $(aws ecs list-services --cluster $SELECTED_CLUSTER --region $REGION --query "serviceArns[0]" --output text) \
    --region $REGION \
    --query "services[0].networkConfiguration.awsvpcConfiguration.subnets[0]" --output text)

if [ -z "$SUBNET_ID" ]; then
    echo "No subnet found for the ECS cluster. Exiting."
    exit 1
fi

VPC_ID=$(aws ec2 describe-subnets --subnet-ids $SUBNET_ID --region $REGION --query "Subnets[0].VpcId" --output text)

if [ -z "$VPC_ID" ]; then
    echo "Could not determine the VPC associated with the ECS cluster. Exiting."
    exit 1
fi

echo "VPC ID: $VPC_ID"

# Stop Active Tasks in the Cluster
echo "Stopping tasks in cluster $SELECTED_CLUSTER..."
TASKS=$(aws ecs list-tasks --cluster $SELECTED_CLUSTER --region $REGION --query "taskArns[]" --output text)

for TASK in $TASKS; do
    echo "Stopping task: $TASK"
    aws ecs stop-task --cluster $SELECTED_CLUSTER --task $TASK --region $REGION > /dev/null
done

# Wait for tasks to stop
echo "Waiting for tasks to stop..."
while true; do
    TASK_COUNT=$(aws ecs list-tasks --cluster $SELECTED_CLUSTER --region $REGION --query "taskArns | length(@)" --output text)
    if [ "$TASK_COUNT" -eq 0 ]; then
        break
    fi
    echo "Waiting for $TASK_COUNT tasks to stop..."
    sleep 10
done

# Delete Services in the Cluster
echo "Deleting services in cluster $SELECTED_CLUSTER..."
SERVICES=$(aws ecs list-services --cluster $SELECTED_CLUSTER --region $REGION --query "serviceArns[]" --output text)

for SERVICE in $SERVICES; do
    echo "Deleting service: $SERVICE"
    aws ecs update-service --cluster $SELECTED_CLUSTER --service $SERVICE --desired-count 0 --region $REGION > /dev/null
    aws ecs delete-service --cluster $SELECTED_CLUSTER --service $SERVICE --region $REGION --force > /dev/null
done

# Query and Delete ECR Repositories
echo "Querying task definitions for ECR repositories..."
TASK_DEFINITIONS=$(aws ecs list-task-definitions --family-prefix $SELECTED_CLUSTER --region $REGION --query "taskDefinitionArns[]" --output text)

for TASK_DEF_ARN in $TASK_DEFINITIONS; do
    echo "Inspecting task definition: $TASK_DEF_ARN"
    IMAGE=$(aws ecs describe-task-definition --task-definition $TASK_DEF_ARN --region $REGION --query "taskDefinition.containerDefinitions[0].image" --output text)

    # Extract repository name from the image URI
    REPO_NAME=$(echo $IMAGE | awk -F'/' '{print $2}' | awk -F':' '{print $1}')
    if [ -n "$REPO_NAME" ]; then
        echo "Deleting ECR repository: $REPO_NAME"
        aws ecr delete-repository --repository-name $REPO_NAME --region $REGION --force > /dev/null
    else
        echo "No ECR repository found in task definition $TASK_DEF_ARN."
    fi
done

# Fetch Public IPs for Later Release
echo "Fetching public IPs associated with VPC $VPC_ID..."
PUBLIC_IPS=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" --region $REGION --query "NetworkInterfaces[].Association.PublicIp" --output text)

# Store public IPs for later release
if [ -n "$PUBLIC_IPS" ]; then
    echo "Public IPs found: $PUBLIC_IPS"
else
    echo "No public IPs associated with VPC $VPC_ID."
fi

# Delete the ECS Cluster
echo "Deleting ECS cluster: $SELECTED_CLUSTER..."
aws ecs delete-cluster --cluster $SELECTED_CLUSTER --region $REGION > /dev/null

# Release Elastic IPs
echo "Releasing Elastic IPs..."
for PUBLIC_IP in $PUBLIC_IPS; do
    ALLOC_ID=$(aws ec2 describe-addresses --filters "Name=public-ip,Values=$PUBLIC_IP" --region $REGION --query "Addresses[0].AllocationId" --output text)
    if [ -n "$ALLOC_ID" ]; then
        echo "Releasing Elastic IP: $PUBLIC_IP (Allocation ID: $ALLOC_ID)"
        aws ec2 release-address --allocation-id $ALLOC_ID --region $REGION > /dev/null
    fi
done

# Delete Subnets
echo "Deleting subnets associated with VPC $VPC_ID..."
SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --region $REGION --query "Subnets[].SubnetId" --output text)

for SUBNET_ID in $SUBNET_IDS; do
    echo "Deleting subnet: $SUBNET_ID"
    aws ec2 delete-subnet --subnet-id $SUBNET_ID --region $REGION > /dev/null
done

# Delete Internet Gateways
echo "Deleting internet gateways associated with VPC $VPC_ID..."
IGW_IDS=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --region $REGION --query "InternetGateways[].InternetGatewayId" --output text)

for IGW_ID in $IGW_IDS; do
    echo "Detaching and deleting internet gateway: $IGW_ID"
    aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID --region $REGION > /dev/null
    aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID --region $REGION > /dev/null
done

# Delete the VPC
echo "Deleting VPC: $VPC_ID"
aws ec2 delete-vpc --vpc-id $VPC_ID --region $REGION > /dev/null

echo "ECS cluster, associated resources, public IPs, and VPC deleted successfully."