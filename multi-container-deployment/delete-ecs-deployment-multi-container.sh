#!/bin/bash

# set -euo pipefail

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

# Function to wait for ENIs to be deleted
wait_for_enis() {
    local vpc_id=$1
    echo "Waiting for Network Interfaces to be deleted... Patience, young grasshopper..."
    local timeout=300
    local end=$((SECONDS + timeout))
    
    while [ $SECONDS -lt $end ]; do
        ENIs=$(aws ec2 describe-network-interfaces \
            --filters "Name=vpc-id,Values=$vpc_id" \
            --region $REGION \
            --query 'NetworkInterfaces[*].NetworkInterfaceId' \
            --output text)
        if [ -z "$ENIs" ]; then
            echo "All Network Interfaces deleted"
            return 0
        fi
        echo "Found ENIs: $ENIs"
        echo "Waiting for ENI deletion... $((end - SECONDS))s remaining"
        sleep 10
    done
    echo "Timeout waiting for ENI deletion"
    return 1
}

# Function to wait for ECS tasks to stop
wait_for_tasks_to_stop() {
    local cluster=$1
    echo "Waiting for tasks to stop..."
    local timeout=300
    local end=$((SECONDS + timeout))
    
    while [ $SECONDS -lt $end ]; do
        TASKS=$(aws ecs list-tasks --cluster "$cluster" --region "$REGION" --query "taskArns[]" --output text)
        if [ -z "$TASKS" ] || [ "$TASKS" == "None" ]; then
            echo "All tasks stopped"
            return 0
        fi
        echo "Waiting for tasks to stop... $((end - SECONDS))s remaining"
        sleep 10
    done
    echo "Timeout waiting for tasks to stop"
    return 1
}

# Function to wait for ECS service deletion
wait_for_service_deletion() {
    local cluster=$1
    local service=$2
    echo "Waiting for service $service to be deleted..."
    local timeout=300
    local end=$((SECONDS + timeout))
    
    while [ $SECONDS -lt $end ]; do
        # Check if service still exists in the cluster
        SERVICE_EXISTS=$(aws ecs list-services --cluster "$cluster" --region "$REGION" \
            --query "contains(serviceArns[], '$service')" --output text)
        if [ "$SERVICE_EXISTS" == "False" ] || [ -z "$SERVICE_EXISTS" ]; then
            echo "Service $service no longer exists in cluster"
            return 0
        fi
        echo "Waiting for service deletion... $((end - SECONDS))s remaining"
        sleep 10
    done
    echo "Timeout waiting for service deletion"
    return 1
}

# 0. List ECS Clusters
echo "Fetching ECS clusters in region $REGION..."
CLUSTERS=$(aws ecs list-clusters --region "$REGION" --query "clusterArns[]" --output text)

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

# Prompt for Cluster Selection
echo ""
read -p "Enter the number of the ECS cluster to DELETE. ALL associated resouces will be DELETED: " CLUSTER_SELECTION
SELECTED_CLUSTER=${CLUSTER_MAP[$CLUSTER_SELECTION]}

if [ -z "$SELECTED_CLUSTER" ]; then
    echo "Invalid selection. Exiting."
    exit 1
fi

echo "Selected Cluster: $SELECTED_CLUSTER"

# 1. Identify VPC and Load Balancers
echo "Finding associated resources..."
SERVICE_ARN=$(aws ecs list-services --cluster "$SELECTED_CLUSTER" --region "$REGION" --query "serviceArns[0]" --output text)

VPC_ID=""
LB_ARNS=""

if [ -n "$SERVICE_ARN" ] && [ "$SERVICE_ARN" != "None" ]; then
    # Get the first service's network configuration to find VPC
    SERVICE_DESC=$(aws ecs describe-services \
        --cluster "$SELECTED_CLUSTER" \
        --services "$SERVICE_ARN" \
        --region "$REGION" \
        --output json)
    
    # Extract subnet ID from the service description
    SUBNET_ID=$(echo "$SERVICE_DESC" | jq -r '.services[0].networkConfiguration.awsvpcConfiguration.subnets[0] // empty')
    
    if [ -n "$SUBNET_ID" ]; then
        # Get VPC ID from the subnet
        VPC_ID=$(aws ec2 describe-subnets \
            --subnet-ids "$SUBNET_ID" \
            --region "$REGION" \
            --query "Subnets[0].VpcId" \
            --output text)
    fi
    
    # Get Load Balancer ARNs (if using an ALB/NLB with the service)
    TARGET_GROUP_ARNS=$(echo "$SERVICE_DESC" | jq -r '.services[0].loadBalancers[].targetGroupArn // empty')
    if [ -n "$TARGET_GROUP_ARNS" ]; then
        LB_ARNS=$(aws elbv2 describe-target-groups \
            --target-group-arns $TARGET_GROUP_ARNS \
            --region "$REGION" \
            --query 'TargetGroups[0].LoadBalancerArns[0]' \
            --output text)
    fi
fi

if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
    echo "Could not determine VPC ID. Exiting."
    exit 1
fi

echo "Found VPC ID: $VPC_ID"

# 2. Stop ECS Tasks
echo "Stopping running tasks in the cluster..."
TASKS=$(aws ecs list-tasks --cluster "$SELECTED_CLUSTER" --region "$REGION" --query "taskArns[]" --output text)
if [ -n "$TASKS" ] && [ "$TASKS" != "None" ]; then
    for TASK in $TASKS; do
        echo "Stopping task: $TASK"
        aws ecs stop-task --cluster "$SELECTED_CLUSTER" --task "$TASK" --region "$REGION" >/dev/null 2>&1 || true
    done
    wait_for_tasks_to_stop "$SELECTED_CLUSTER"
fi

# 3. Delete ECS Services
echo "Deleting ECS services..."
SERVICES=$(aws ecs list-services --cluster "$SELECTED_CLUSTER" --region "$REGION" --query "serviceArns[]" --output text)
if [ -n "$SERVICES" ] && [ "$SERVICES" != "None" ]; then
    for SERVICE in $SERVICES; do
        echo "Updating service $SERVICE to desired count 0..."
        aws ecs update-service \
            --cluster "$SELECTED_CLUSTER" \
            --service "$SERVICE" \
            --desired-count 0 \
            --region "$REGION" >/dev/null 2>&1 || true
        
        echo "Deleting service: $SERVICE"
        aws ecs delete-service \
            --cluster "$SELECTED_CLUSTER" \
            --service "$SERVICE" \
            --force \
            --region "$REGION" >/dev/null 2>&1 || true
        
        wait_for_service_deletion "$SELECTED_CLUSTER" "$SERVICE"
    done
fi

# 4. Delete Load Balancer Resources (if any)
if [ -n "$LB_ARNS" ] && [ "$LB_ARNS" != "None" ]; then
    for LB_ARN in $LB_ARNS; do
        echo "Processing Load Balancer: $LB_ARN"
        
        # Get target groups
        echo "Finding target groups for load balancer..."
        TARGET_GROUPS=$(aws elbv2 describe-target-groups \
            --load-balancer-arn "$LB_ARN" \
            --region "$REGION" \
            --query 'TargetGroups[*].TargetGroupArn' \
            --output text || echo "")
            
        # Delete listeners
        echo "Finding listeners for load balancer..."
        LISTENERS=$(aws elbv2 describe-listeners \
            --load-balancer-arn "$LB_ARN" \
            --region "$REGION" \
            --query 'Listeners[*].ListenerArn' \
            --output text || echo "")
            
        if [ -n "$LISTENERS" ]; then
            for LISTENER in $LISTENERS; do
                echo "Deleting listener: $LISTENER"
                aws elbv2 delete-listener \
                    --listener-arn "$LISTENER" \
                    --region "$REGION" >/dev/null 2>&1 || true
            done
        fi
        
        # Delete the load balancer
        echo "Deleting load balancer: $LB_ARN"
        aws elbv2 delete-load-balancer \
            --load-balancer-arn "$LB_ARN" \
            --region "$REGION" >/dev/null 2>&1 || true
            
        # Wait for load balancer to be deleted
        echo "Waiting for load balancer deletion..."
        while true; do
            LB_EXISTS=$(aws elbv2 describe-load-balancers \
                --load-balancer-arns "$LB_ARN" \
                --region "$REGION" 2>/dev/null || echo "NOT_FOUND")
            if [ "$LB_EXISTS" == "NOT_FOUND" ]; then
                break
            fi
            sleep 10
        done
        
        # Now delete target groups
        if [ -n "$TARGET_GROUPS" ]; then
            for TG in $TARGET_GROUPS; do
                echo "Deleting target group: $TG"
                aws elbv2 delete-target-group \
                    --target-group-arn "$TG" \
                    --region "$REGION" >/dev/null 2>&1 || true
            done
        fi
    done
fi

# 5. Delete ECR Repositories (based on images used in services)
#    (This might fail silently if no repos exist or if you have other repos not used by these services)
echo "Cleaning up ECR repositories used by these services..."
if [ -n "$SERVICES" ] && [ "$SERVICES" != "None" ]; then
    for SERVICE in $SERVICES; do
        TASK_DEFINITION=$(aws ecs describe-services \
            --cluster "$SELECTED_CLUSTER" \
            --services "$SERVICE" \
            --region "$REGION" \
            --query "services[0].taskDefinition" \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$TASK_DEFINITION" ] && [ "$TASK_DEFINITION" != "None" ]; then
            CONTAINERS=$(aws ecs describe-task-definition \
                --task-definition "$TASK_DEFINITION" \
                --region "$REGION" \
                --query "taskDefinition.containerDefinitions[*].image" \
                --output text 2>/dev/null || echo "")
            
            for IMAGE in $CONTAINERS; do
                # Typically <account_id>.dkr.ecr.<region>.amazonaws.com/<repo_name>:<tag>
                # We extract the repository part: ...
                REPO_NAME=$(echo "$IMAGE" | awk -F'/' '{print $2}' | awk -F':' '{print $1}')
                if [ -n "$REPO_NAME" ]; then
                    echo "Deleting ECR repository: $REPO_NAME"
                    aws ecr delete-repository \
                        --repository-name "$REPO_NAME" \
                        --force \
                        --region "$REGION" >/dev/null 2>&1 || true
                fi
            done
        fi
    done
fi

# 6. Deregister ECS Task Definitions
#    We'll only deregister families used by the above services to avoid impacting other clusters.
echo "Deregistering ECS Task Definitions used by the services in this cluster..."
declare -A FAMILY_SET=()
if [ -n "$SERVICES" ] && [ "$SERVICES" != "None" ]; then
    for SERVICE in $SERVICES; do
        TASK_DEFINITION=$(aws ecs describe-services \
            --cluster "$SELECTED_CLUSTER" \
            --services "$SERVICE" \
            --region "$REGION" \
            --query "services[0].taskDefinition" \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$TASK_DEFINITION" ] && [ "$TASK_DEFINITION" != "None" ]; then
            FAMILY=$(aws ecs describe-task-definition \
                --task-definition "$TASK_DEFINITION" \
                --region "$REGION" \
                --query "taskDefinition.family" \
                --output text 2>/dev/null || echo "")
            if [ -n "$FAMILY" ] && [ "$FAMILY" != "None" ]; then
                FAMILY_SET["$FAMILY"]=1
            fi
        fi
    done
fi

for FAMILY in "${!FAMILY_SET[@]}"; do
    echo "Listing all versions of family: $FAMILY"
    TDS=$(aws ecs list-task-definitions \
        --family-prefix "$FAMILY" \
        --region "$REGION" \
        --query "taskDefinitionArns[]" \
        --output text 2>/dev/null || echo "")
    if [ -n "$TDS" ]; then
        for TD_ARN in $TDS; do
            echo "Deregistering task definition: $TD_ARN"
            aws ecs deregister-task-definition \
                --task-definition "$TD_ARN" \
                --region "$REGION" >/dev/null 2>&1 || true
        done
    fi
done

# 7. Delete the ECS Cluster
echo "Deleting ECS cluster: $SELECTED_CLUSTER"
aws ecs delete-cluster --cluster "$SELECTED_CLUSTER" --region "$REGION" >/dev/null 2>&1 || true

# 8. Wait for ENIs to be deleted (some can linger after NAT/ALB teardown)
echo "Waiting for network interfaces to be cleaned up..."
wait_for_enis "$VPC_ID"

# 9. Delete NAT Gateways
echo "Checking for NAT Gateways..."
NAT_GATEWAYS=$(aws ec2 describe-nat-gateways \
    --filter "Name=vpc-id,Values=$VPC_ID" \
    --region "$REGION" \
    --query 'NatGateways[*].NatGatewayId' \
    --output text)

if [ -n "$NAT_GATEWAYS" ]; then
    for NAT_GW in $NAT_GATEWAYS; do
        echo "Deleting NAT Gateway: $NAT_GW"
        aws ec2 delete-nat-gateway \
            --nat-gateway-id "$NAT_GW" \
            --region "$REGION" >/dev/null 2>&1 || true
        
        # Wait for NAT Gateway deletion
        echo "Waiting for NAT Gateway deletion..."
        while true; do
            NAT_STATE=$(aws ec2 describe-nat-gateways \
                --nat-gateway-ids "$NAT_GW" \
                --region "$REGION" \
                --query 'NatGateways[0].State' \
                --output text 2>/dev/null || echo "deleted")
            
            if [ "$NAT_STATE" == "deleted" ]; then
                break
            fi
            echo "NAT Gateway status: $NAT_STATE"
            sleep 10
        done
    done
fi

# 10. Detach and Delete Internet Gateways
echo "Checking for Internet Gateways..."
IGW_IDS=$(aws ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --region "$REGION" \
    --query 'InternetGateways[*].InternetGatewayId' \
    --output text)

if [ -n "$IGW_IDS" ]; then
    for IGW_ID in $IGW_IDS; do
        echo "Detaching Internet Gateway: $IGW_ID"
        aws ec2 detach-internet-gateway \
            --internet-gateway-id "$IGW_ID" \
            --vpc-id "$VPC_ID" \
            --region "$REGION" >/dev/null 2>&1 || true
        
        echo "Deleting Internet Gateway: $IGW_ID"
        aws ec2 delete-internet-gateway \
            --internet-gateway-id "$IGW_ID" \
            --region "$REGION" >/dev/null 2>&1 || true
    done
fi

# 11. Delete Subnets
ATTEMPT=0
MAX_ATTEMPTS=60
DELAY=5
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

# 12. Delete Route Tables (non-main)
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

# 13. Delete Security Groups (non-default)
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

# 14. Delete VPC
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

# 15. Delete CloudWatch Log Groups (example: /ecs/ecs-task)
LOG_GROUP_NAME="/ecs/ecs-task"
echo "Deleting CloudWatch Log Group: $LOG_GROUP_NAME"
aws logs delete-log-group --log-group-name "$LOG_GROUP_NAME" --region "$REGION" >/dev/null 2>&1 || true

echo "Cleanup completed successfully!"