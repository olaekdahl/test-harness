#!/bin/bash

cat << "EOF"
  ______ _____  _____   _______ ______  _____ _______   _    _          _____  _   _ ______  _____ _____ 
 |  ____/ ____|/ ____| |__   __|  ____|/ ____|__   __| | |  | |   /\   |  __ \| \ | |  ____|/ ____/ ____|
 | |__ | |    | (___      | |  | |__  | (___    | |    | |__| |  /  \  | |__) |  \| | |__  | (___| (___  
 |  __|| |     \___ \     | |  |  __|  \___ \   | |    |  __  | / /\ \ |  _  /| . ` |  __|  \___ \\\___ \ 
 | |___| |____ ____) |    | |  | |____ ____) |  | |    | |  | |/ ____ \| | \ \| |\  | |____ ____) |___) |
 |______\_____|_____/     |_|  |______|_____/   |_|    |_|  |_/_/    \_\_|  \_\_| \_|______|_____/_____/ 
EOF

printf "\n\n"

# Set AWS Region
REGION="us-west-2"

MAX_ATTEMPTS=60
ATTEMPT=0
DELAY=5

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

# Query Task Definitions and ECR Repositories Associated with Selected Cluster
echo "Querying services in cluster $SELECTED_CLUSTER..."
SERVICES=$(aws ecs list-services --cluster $SELECTED_CLUSTER --region $REGION --query "serviceArns[]" --output text)

if [ -z "$SERVICES" ]; then
    echo "No services found in cluster $SELECTED_CLUSTER."
else
    echo "Services found: $SERVICES"

    for SERVICE in $SERVICES; do
        TASK_DEFINITION=$(aws ecs describe-services \
            --cluster $SELECTED_CLUSTER \
            --services $SERVICE \
            --region $REGION \
            --query "services[0].taskDefinition" \
            --output text)

        if [ -n "$TASK_DEFINITION" ]; then
            echo "Found task definition: $TASK_DEFINITION for service $SERVICE"

            IMAGE=$(aws ecs describe-task-definition --task-definition $TASK_DEFINITION --region $REGION --query "taskDefinition.containerDefinitions[0].image" --output text)

            # Extract repository name from the image URI
            REPO_NAME=$(echo $IMAGE | awk -F'/' '{print $2}' | awk -F':' '{print $1}')
            if [ -n "$REPO_NAME" ]; then
                echo "Deleting ECR repository: $REPO_NAME"
                aws ecr delete-repository --repository-name $REPO_NAME --region $REGION --force > /dev/null
            else
                echo "No ECR repository found in task definition $TASK_DEFINITION."
            fi

            while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do
                echo "Attempting to deregister task definition: $TASK_DEFINITION"
                aws ecs deregister-task-definition --task-definition $TASK_DEFINITION --region $REGION > /dev/null 2>&1

                if [ $? -eq 0 ]; then
                    echo "Task definition $TASK_DEFINITION deregistered successfully."
                    break
                else
                    echo "Failed to deregister task definition $TASK_DEFINITION. Retrying in $DELAY seconds..."
                fi

                ATTEMPT=$((ATTEMPT + 1))
                if [ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]; then
                    echo "Max attempts reached for deregistering task definition $TASK_DEFINITION. Exiting with failure."
                    exit 1
                fi

                sleep $DELAY
            done
            ATTEMPT=0  # Reset attempt counter for the next task definition
        fi
    done
fi

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

# Delete the ECS Cluster
echo "Deleting ECS cluster: $SELECTED_CLUSTER..."
aws ecs delete-cluster --cluster $SELECTED_CLUSTER --region $REGION > /dev/null

# Fetch Internet Gateways
echo "Deleting internet gateways associated with VPC $VPC_ID..."
IGW_IDS=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --region $REGION --query "InternetGateways[].InternetGatewayId" --output text)

for IGW_ID in $IGW_IDS; do
    while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do
        echo "Attempting to detach internet gateway: $IGW_ID"
        aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID --region $REGION > /dev/null 2>&1

        if [ $? -eq 0 ]; then
            echo "Internet gateway $IGW_ID detached successfully."
            echo "Deleting internet gateway: $IGW_ID"
            aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID --region $REGION > /dev/null 2>&1

            if [ $? -eq 0 ]; then
                echo "Internet gateway $IGW_ID deleted successfully."
                break
            else
                echo "Failed to delete internet gateway $IGW_ID. Retrying in $DELAY seconds..."
            fi
        else
            echo "Dependency violation detected for internet gateway $IGW_ID. Retrying in $DELAY seconds..."
        fi

        ATTEMPT=$((ATTEMPT + 1))
        if [ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]; then
            echo "Max attempts reached for detaching internet gateway $IGW_ID. Exiting with failure."
            exit 1
        fi

        sleep $DELAY
    done
    ATTEMPT=0  # Reset attempt counter for the next internet gateway
done

# Delete Subnets
ATTEMPT=0
echo "Deleting subnets associated with VPC $VPC_ID..."
SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --region $REGION --query "Subnets[].SubnetId" --output text)

for SUBNET_ID in $SUBNET_IDS; do
    while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do
        echo "Attempting to delete subnet: $SUBNET_ID"
        aws ec2 delete-subnet --subnet-id $SUBNET_ID --region $REGION > /dev/null 2>&1

        if [ $? -eq 0 ]; then
            echo "Subnet $SUBNET_ID deleted successfully."
            break
        else
            echo "Failed to delete subnet $SUBNET_ID. Retrying in $DELAY seconds..."
        fi

        ATTEMPT=$((ATTEMPT + 1))
        if [ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]; then
            echo "Max attempts reached for deleting subnet $SUBNET_ID. Exiting with failure."
            exit 1
        fi

        sleep $DELAY
    done
    ATTEMPT=0  # Reset attempt counter for the next subnet
done

# Delete Route Tables
ATTEMPT=0
echo "Deleting route tables associated with VPC $VPC_ID..."
ROUTE_TABLE_IDS=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --region $REGION --query "RouteTables[].RouteTableId" --output text)
MAIN_ROUTE_TABLE_ID=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" --region $REGION --query "RouteTables[0].RouteTableId" --output text)

for ROUTE_TABLE_ID in $ROUTE_TABLE_IDS; do
    if [ "$ROUTE_TABLE_ID" == "$MAIN_ROUTE_TABLE_ID" ]; then
        echo "Route table $ROUTE_TABLE_ID is the main route table for VPC $VPC_ID. Skipping deletion."
        continue
    fi

    while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do
        echo "Attempting to delete route table: $ROUTE_TABLE_ID"
        aws ec2 delete-route-table --route-table-id $ROUTE_TABLE_ID --region $REGION > /dev/null 2>&1

        if [ $? -eq 0 ]; then
            echo "Route table $ROUTE_TABLE_ID deleted successfully."
            break
        else
            echo "Failed to delete route table $ROUTE_TABLE_ID. Retrying in $DELAY seconds..."
        fi

        ATTEMPT=$((ATTEMPT + 1))
        if [ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]; then
            echo "Max attempts reached for deleting route table $ROUTE_TABLE_ID. Exiting with failure."
            exit 1
        fi

        sleep $DELAY
    done
    ATTEMPT=0  # Reset attempt counter for the next route table
done

# Delete Security Groups
ATTEMPT=0
echo "Deleting security groups associated with VPC $VPC_ID..."
SECURITY_GROUP_IDS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --region $REGION --query "SecurityGroups[?GroupName!='default'].GroupId" --output text)

for SECURITY_GROUP_ID in $SECURITY_GROUP_IDS; do
    while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do
        echo "Attempting to delete security group: $SECURITY_GROUP_ID"
        aws ec2 delete-security-group --group-id $SECURITY_GROUP_ID --region $REGION > /dev/null 2>&1

        if [ $? -eq 0 ]; then
            echo "Security group $SECURITY_GROUP_ID deleted successfully."
            break
        else
            echo "Failed to delete security group $SECURITY_GROUP_ID. Retrying in $DELAY seconds..."
        fi

        ATTEMPT=$((ATTEMPT + 1))
        if [ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]; then
            echo "Max attempts reached for deleting security group $SECURITY_GROUP_ID. Exiting with failure."
            exit 1
        fi

        sleep $DELAY
    done
    ATTEMPT=0  # Reset attempt counter for the next security group
done

# Delete the VPC
ATTEMPT=0
echo "Deleting VPC: $VPC_ID"
while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do
    aws ec2 delete-vpc --vpc-id $VPC_ID --region $REGION > /dev/null 2>&1

    if [ $? -eq 0 ]; then
        echo "VPC $VPC_ID deleted successfully."
        break
    else
        echo "Failed to delete VPC $VPC_ID. Retrying in $DELAY seconds..."
    fi

    ATTEMPT=$((ATTEMPT + 1))
    if [ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]; then
        echo "Max attempts reached for deleting VPC $VPC_ID. Exiting with failure."
        exit 1
    fi

    sleep $DELAY
done

echo "ECS cluster, associated resources, and VPC deleted successfully."