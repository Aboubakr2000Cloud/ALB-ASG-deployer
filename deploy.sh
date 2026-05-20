#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.env"
source "$SCRIPT_DIR/.deploy_state" 2>/dev/null || true
export AWS_DEFAULT_REGION="$REGION"

run_part_a() {

  echo "Deploying infrastructure..."

  # Create VPC
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --query 'Vpc.VpcId' \
  --output text \
  --tag-specifications "ResourceType=vpc,Tags=[
    {Key=Name,Value=week13-vpc},
    {Key=Project,Value=$PROJECT_TAG},
    {Key=Week,Value=$WEEK_TAG}
  ]")
  
echo "VPC created: $VPC_ID"  

# Enable DNS hostnames and support
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support

# Create IGW
IGW_ID=$(aws ec2 create-internet-gateway \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --tag-specifications "ResourceType=internet-gateway,Tags=[
    {Key=Name,Value=week13-igw},
    {Key=Project,Value=$PROJECT_TAG},
    {Key=Week,Value=$WEEK_TAG}
  ]")
  
# Attach to VPC
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"

# Create public subnet 1
PUBLIC_SUBNET_1_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$PUBLIC_SUBNET_1_CIDR" \
  --availability-zone "$AZ_1" \
  --query 'Subnet.SubnetId' \
  --output text \
  --tag-specifications "ResourceType=subnet,Tags=[
    {Key=Name,Value=week13-public-subnet-1},
    {Key=Project,Value=$PROJECT_TAG},
    {Key=Week,Value=$WEEK_TAG}
  ]")
  
# Create public subnet 2
PUBLIC_SUBNET_2_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$PUBLIC_SUBNET_2_CIDR" \
  --availability-zone "$AZ_2" \
  --query 'Subnet.SubnetId' \
  --output text \
  --tag-specifications "ResourceType=subnet,Tags=[
    {Key=Name,Value=week13-public-subnet-2},
    {Key=Project,Value=$PROJECT_TAG},
    {Key=Week,Value=$WEEK_TAG}
  ]")
  
echo "Public subnets: $PUBLIC_SUBNET_1_ID, $PUBLIC_SUBNET_2_ID"

# Create private subnet 1
PRIVATE_SUBNET_1_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$PRIVATE_SUBNET_1_CIDR" \
  --availability-zone "$AZ_1" \
  --query 'Subnet.SubnetId' \
  --output text \
  --tag-specifications "ResourceType=subnet,Tags=[
    {Key=Name,Value=week13-private-subnet-1},
    {Key=Project,Value=$PROJECT_TAG},
    {Key=Week,Value=$WEEK_TAG}
  ]")
  
# Create private subnet 2
PRIVATE_SUBNET_2_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$PRIVATE_SUBNET_2_CIDR" \
  --availability-zone "$AZ_2" \
  --query 'Subnet.SubnetId' \
  --output text \
  --tag-specifications "ResourceType=subnet,Tags=[
    {Key=Name,Value=week13-private-subnet-2},
    {Key=Project,Value=$PROJECT_TAG},
    {Key=Week,Value=$WEEK_TAG}
  ]")

echo "Private subnets: $PRIVATE_SUBNET_1_ID, $PRIVATE_SUBNET_2_ID"

# Enable auto-assign public IP on public subnet 1
aws ec2 modify-subnet-attribute \
  --subnet-id "$PUBLIC_SUBNET_1_ID" \
  --map-public-ip-on-launch
  
# Enable auto-assign public IP on public subnet 2
aws ec2 modify-subnet-attribute \
  --subnet-id "$PUBLIC_SUBNET_2_ID" \
  --map-public-ip-on-launch
  
# Create public route table
PUBLIC_ROUTE_TABLE_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --tag-specifications "ResourceType=route-table,Tags=[
    {Key=Name,Value=week13-public-rt},
    {Key=Project,Value=$PROJECT_TAG},
    {Key=Week,Value=$WEEK_TAG}
  ]") >/dev/null

echo "Public route table: $PUBLIC_ROUTE_TABLE_ID"

# Add 0.0.0.0/0 route to IGW
aws ec2 create-route \
  --route-table-id "$PUBLIC_ROUTE_TABLE_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$IGW_ID"
  
# Associate public route table with public subnets
PUBLIC_RT_ASSOC_1_ID=$(aws ec2 associate-route-table \
  --route-table-id "$PUBLIC_ROUTE_TABLE_ID" \
  --subnet-id "$PUBLIC_SUBNET_1_ID" \
  --query 'AssociationId' \
  --output text)

PUBLIC_RT_ASSOC_2_ID=$(aws ec2 associate-route-table \
  --route-table-id "$PUBLIC_ROUTE_TABLE_ID" \
  --subnet-id "$PUBLIC_SUBNET_2_ID" \
  --query 'AssociationId' \
  --output text)
  
# Allocate an Elastic IP for the NAT Gateway
ALLOCATION_ID=$(aws ec2 allocate-address \
  --domain vpc \
  --query 'AllocationId' \
  --output text)
  
# Tag elastic IP
aws ec2 create-tags \
  --resources "$ALLOCATION_ID" \
  --tags Key=Name,Value=week13-eip \
         Key=Project,Value=$PROJECT_TAG \
         Key=Week,Value=$WEEK_TAG
         
# Create NAT Gateway in public subnet 1
NAT_ID=$(aws ec2 create-nat-gateway \
  --subnet-id "$PUBLIC_SUBNET_1_ID" \
  --allocation-id "$ALLOCATION_ID" \
  --query 'NatGateway.NatGatewayId' \
  --output text \
  --tag-specifications "ResourceType=natgateway,Tags=[
    {Key=Name,Value=week13-nat},
    {Key=Project,Value=$PROJECT_TAG},
    {Key=Week,Value=$WEEK_TAG}
  ]")
  
# Wait for the NAT Gateway to be available
echo "Waiting for NAT Gateway to become available..."

while true; do
    STATE=$(aws ec2 describe-nat-gateways \
      --nat-gateway-ids "$NAT_ID" \
      --query 'NatGateways[0].State' \
      --output text)
    [ "$STATE" = "available" ] && break
    echo "NAT state: $STATE — waiting..."
    sleep 10
done  
 
echo "NAT Gateway: $NAT_ID (available)" 
 
# Create private route table
PRIVATE_ROUTE_TABLE_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --tag-specifications "ResourceType=route-table,Tags=[
    {Key=Name,Value=week13-private-rt},
    {Key=Project,Value=$PROJECT_TAG},
    {Key=Week,Value=$WEEK_TAG}
  ]") >/dev/null

echo "Private route table: $PRIVATE_ROUTE_TABLE_ID"

# Add 0.0.0.0/0 route to NAT
aws ec2 create-route \
  --route-table-id "$PRIVATE_ROUTE_TABLE_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --nat-gateway-id "$NAT_ID"
  
# Associate private route table with private subnets
PRIVATE_RT_ASSOC_1_ID=$(aws ec2 associate-route-table \
  --route-table-id "$PRIVATE_ROUTE_TABLE_ID" \
  --subnet-id "$PRIVATE_SUBNET_1_ID" \
  --query 'AssociationId' \
  --output text)
  
PRIVATE_RT_ASSOC_2_ID=$(aws ec2 associate-route-table \
  --route-table-id "$PRIVATE_ROUTE_TABLE_ID" \
  --subnet-id "$PRIVATE_SUBNET_2_ID" \
  --query 'AssociationId' \
  --output text)  
  
# Save all resource IDs to .deploy_state
cat > "$SCRIPT_DIR/.deploy_state" << EOF
VPC_ID="$VPC_ID"
PUBLIC_SUBNET_1_ID="$PUBLIC_SUBNET_1_ID"
PUBLIC_SUBNET_2_ID="$PUBLIC_SUBNET_2_ID"
PRIVATE_SUBNET_1_ID="$PRIVATE_SUBNET_1_ID"
PRIVATE_SUBNET_2_ID="$PRIVATE_SUBNET_2_ID"
IGW_ID="$IGW_ID"
PUBLIC_ROUTE_TABLE_ID="$PUBLIC_ROUTE_TABLE_ID"
PUBLIC_RT_ASSOC_1_ID="$PUBLIC_RT_ASSOC_1_ID"
PUBLIC_RT_ASSOC_2_ID="$PUBLIC_RT_ASSOC_2_ID"
PRIVATE_ROUTE_TABLE_ID="$PRIVATE_ROUTE_TABLE_ID"
PRIVATE_RT_ASSOC_1_ID="$PRIVATE_RT_ASSOC_1_ID"
PRIVATE_RT_ASSOC_2_ID="$PRIVATE_RT_ASSOC_2_ID"
ALLOCATION_ID="$ALLOCATION_ID"
NAT_ID="$NAT_ID"
EOF
}

if [ -f "$SCRIPT_DIR/.deploy_state" ]; then
  echo "Infrastructure already exists. Loading state..."
else
  run_part_a
fi

source "$SCRIPT_DIR/.deploy_state"

run_part_b() {

: "${VPC_ID:?Missing VPC_ID}"

MY_IP=$(curl -s checkip.amazonaws.com)

ALB_SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="$ALB_SG_NAME" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)
  
  if [ "$ALB_SG_ID" = "None" ]; then
     echo "Creating Application load balancer SG..."
  
     ALB_SG_ID=$(aws ec2 create-security-group \
     --vpc-id "$VPC_ID" \
     --group-name "$ALB_SG_NAME" \
     --description "Week 13 Application load balancer SG" \
     --query 'GroupId' \
     --output text)

     aws ec2 create-tags \
       --resources "$ALB_SG_ID" \
       --tags Key=Name,Value=week13-ALB-sg Key=Project,Value="$PROJECT_TAG" Key=Week,Value="$WEEK_TAG" >/dev/null

     aws ec2 authorize-security-group-ingress \
       --group-id "$ALB_SG_ID" \
       --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
       
      aws ec2 authorize-security-group-ingress \
       --group-id "$ALB_SG_ID" \
       --protocol tcp --port 443 --cidr 0.0.0.0/0 >/dev/null
  fi

echo "ALB SG: $ALB_SG_ID"

APP_SERVER_SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="$APP_SG_NAME" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)

  if [ "$APP_SERVER_SG_ID" = "None" ]; then
    echo "Creating App server SG..."

    APP_SERVER_SG_ID=$(aws ec2 create-security-group \
      --vpc-id "$VPC_ID" \
      --group-name "$APP_SG_NAME" \
      --description "Week 13 App SG" \
      --query 'GroupId' \
      --output text)

    aws ec2 create-tags \
      --resources "$APP_SERVER_SG_ID" \
      --tags Key=Name,Value=week13-app-server-sg Key=Project,Value="$PROJECT_TAG" Key=Week,Value="$WEEK_TAG" >/dev/null

    aws ec2 authorize-security-group-ingress \
      --group-id "$APP_SERVER_SG_ID" \
      --protocol tcp --port 80 --source-group "$ALB_SG_ID" >/dev/null

    aws ec2 authorize-security-group-ingress \
      --group-id "$APP_SERVER_SG_ID" \
      --protocol tcp --port 22 --cidr "$MY_IP/32" >/dev/null

  fi

echo "APP server SG: $APP_SERVER_SG_ID"

# Create key pair
aws ec2 create-key-pair \
  --key-name "$KEY_NAME" \
  --query 'KeyMaterial' \
  --output text > "$KEY_NAME.pem"

chmod 400 "$KEY_NAME.pem"

# Create Launch Template
LT_ID=$(aws ec2 describe-launch-templates \
  --launch-template-names "$LT_NAME" \
  --query 'LaunchTemplates[0].LaunchTemplateId' \
  --output text 2>/dev/null || echo "None") \
  
if [ "$LT_ID" = "None" ]; then
  echo "Creating launch template"

# Base64-encode userdata for the launch template
USER_DATA_B64=$(base64 -w0 "$SCRIPT_DIR/userdata_alb.sh")

LT_ID=$(aws ec2 create-launch-template \
  --launch-template-name "$LT_NAME" \
  --version-description "v1" \
  --query 'LaunchTemplate.LaunchTemplateId' \
  --launch-template-data "{
    \"ImageId\": \"$AMI_ID\",
    \"InstanceType\": \"$INSTANCE_TYPE\",
    \"KeyName\": \"$KEY_NAME\",
    \"SecurityGroupIds\": [\"$APP_SERVER_SG_ID\"],
    \"UserData\": \"$USER_DATA_B64\",
    \"TagSpecifications\": [{
      \"ResourceType\": \"instance\",
      \"Tags\": [
        {\"Key\": \"Name\", \"Value\": \"week13-asg-instance\"},
        {\"Key\": \"Project\", \"Value\": \"$PROJECT_TAG\"}
      ]
    }]
  }")
  
fi
echo "Launch template: $LT_ID"

# Save all resource IDs to .deploy_state
cat > "$SCRIPT_DIR/.deploy_state" << EOF
# ---- Part A ----
VPC_ID="$VPC_ID"
PUBLIC_SUBNET_1_ID="$PUBLIC_SUBNET_1_ID"
PUBLIC_SUBNET_2_ID="$PUBLIC_SUBNET_2_ID"
PRIVATE_SUBNET_1_ID="$PRIVATE_SUBNET_1_ID"
PRIVATE_SUBNET_2_ID="$PRIVATE_SUBNET_2_ID"
IGW_ID="$IGW_ID"
PUBLIC_ROUTE_TABLE_ID="$PUBLIC_ROUTE_TABLE_ID"
PUBLIC_RT_ASSOC_1_ID="$PUBLIC_RT_ASSOC_1_ID"
PUBLIC_RT_ASSOC_2_ID="$PUBLIC_RT_ASSOC_2_ID"
PRIVATE_ROUTE_TABLE_ID="$PRIVATE_ROUTE_TABLE_ID"
PRIVATE_RT_ASSOC_1_ID="$PRIVATE_RT_ASSOC_1_ID"
PRIVATE_RT_ASSOC_2_ID="$PRIVATE_RT_ASSOC_2_ID"
ALLOCATION_ID="$ALLOCATION_ID"
NAT_ID="$NAT_ID"
# ---- Part B ----
ALB_SG_ID="$ALB_SG_ID"
APP_SERVER_SG_ID="$APP_SERVER_SG_ID"
LT_ID="$LT_ID"

PART_B_DONE=true
EOF
sleep 15
}

if [ "${PART_B_DONE:-false}" = "true" ]; then
  echo "Security groups and template already exists. Loading state..."
else
  run_part_b
fi

run_part_c() {

  : "${ALB_SG_ID:?Missing ALB_SG_ID}"
  : "${PUBLIC_SUBNET_1_ID:?Missing PUBLIC_SUBNET_1_ID}"
  : "${PUBLIC_SUBNET_2_ID:?Missing PUBLIC_SUBNET_2_ID}"
  : "${VPC_ID:?Missing VPC_ID}"
  : "${ALB_NAME:?Missing ALB_NAME}"

# Create the Target Group
TG_ARN=$(aws elbv2 describe-target-groups \
  --names "$TG_NAME" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text 2>/dev/null || echo "None")

if [ "$TG_ARN" = "None" ]; then

TG_ARN=$(aws elbv2 create-target-group \
  --name "$TG_NAME" \
  --protocol HTTP \
  --port 80 \
  --vpc-id "$VPC_ID" \
  --health-check-protocol HTTP \
  --health-check-path "/health" \
  --health-check-interval-seconds 30 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text) >/dev/null
  
fi

echo "Target group: $TG_ARN"

# Set deregistration delay to 60 seconds
aws elbv2 modify-target-group-attributes \
  --target-group-arn "$TG_ARN" \
  --attributes Key=deregistration_delay.timeout_seconds,Value=60
  
# Create the ALB

ALB_ARN=$(aws elbv2 create-load-balancer \
  --name "$ALB_NAME" \
  --subnets "$PUBLIC_SUBNET_1_ID" "$PUBLIC_SUBNET_2_ID" \
  --security-groups "$ALB_SG_ID" \
  --scheme internet-facing \
  --type application \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --tags "Key=Name,Value=$ALB_NAME" Key=Project,Value=$PROJECT_TAG \
  --output text)
 
echo "ALB: $ALB_ARN"

echo "Wait for ALB to be active..."
aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN"
sleep 10
echo "ALB: $ALB_ARN (available)"

# Get the ALB DNS name
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' \
  --output text)

echo "ALB DNS: $ALB_DNS"

# Create the Listener (HTTP:80 → forward to target group):
LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP \
  --port 80 \
  --default-actions "Type=forward,TargetGroupArn=$TG_ARN" \
  --query 'Listeners[0].ListenerArn' \
  --output text)
  
echo "Listener created: $LISTENER_ARN"

# Save all resource IDs to .deploy_state
cat > "$SCRIPT_DIR/.deploy_state" << EOF
# ---- Part A ----
VPC_ID="$VPC_ID"
PUBLIC_SUBNET_1_ID="$PUBLIC_SUBNET_1_ID"
PUBLIC_SUBNET_2_ID="$PUBLIC_SUBNET_2_ID"
PRIVATE_SUBNET_1_ID="$PRIVATE_SUBNET_1_ID"
PRIVATE_SUBNET_2_ID="$PRIVATE_SUBNET_2_ID"
IGW_ID="$IGW_ID"
PUBLIC_ROUTE_TABLE_ID="$PUBLIC_ROUTE_TABLE_ID"
PUBLIC_RT_ASSOC_1_ID="$PUBLIC_RT_ASSOC_1_ID"
PUBLIC_RT_ASSOC_2_ID="$PUBLIC_RT_ASSOC_2_ID"
PRIVATE_ROUTE_TABLE_ID="$PRIVATE_ROUTE_TABLE_ID"
PRIVATE_RT_ASSOC_1_ID="$PRIVATE_RT_ASSOC_1_ID"
PRIVATE_RT_ASSOC_2_ID="$PRIVATE_RT_ASSOC_2_ID"
ALLOCATION_ID="$ALLOCATION_ID"
NAT_ID="$NAT_ID"
# ---- Part B ----
ALB_SG_ID="$ALB_SG_ID"
APP_SERVER_SG_ID="$APP_SERVER_SG_ID"
LT_ID="$LT_ID"
# ---- Part C ----
TG_ARN="$TG_ARN"
ALB_ARN="$ALB_ARN"
ALB_DNS="$ALB_DNS"
LISTENER_ARN="$LISTENER_ARN"

PART_B_DONE=true
PART_C_DONE=true
EOF
}

if [ "${PART_C_DONE:-false}" = "true" ]; then
  echo "ALB, Target group and Listener already created"
else
  run_part_c
fi

run_part_d() {

  : "${PRIVATE_SUBNET_1_ID:?Missing PRIVATE_SUBNET_1_ID}"
  : "${PRIVATE_SUBNET_2_ID:?Missing PRIVATE_SUBNET_2_ID}"
  : "${TG_ARN:?Missing TG_ARN}"
  : "${LT_NAME:?Missing LT_NAME}"
  : "${ASG_NAME:?Missing ASG_NAME}"
  : "${ALB_DNS:?Missing ALB_DNS}"

# Create the ASG
aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name "$ASG_NAME" \
  --launch-template "LaunchTemplateName=$LT_NAME,Version=\$Latest" \
  --min-size 1 \
  --max-size 4 \
  --desired-capacity 2 \
  --target-group-arns "$TG_ARN" \
  --vpc-zone-identifier "$PRIVATE_SUBNET_1_ID,$PRIVATE_SUBNET_2_ID" \
  --health-check-type ELB \
  --health-check-grace-period 120 \
  --query "AutoScalingGroups[0].AutoScalingGroupARN" \
  --tags "Key=Name,Value=week13-asg,PropagateAtLaunch=false" \
         "Key=Project,Value=$PROJECT_TAG,PropagateAtLaunch=true"

ASG_ARN=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].AutoScalingGroupARN' \
  --output text)
  
echo "ASG created: $ASG_ARN"

# Create a Target Tracking scaling policy (CPU target 50%)
POLICY_ARN=$(aws autoscaling put-scaling-policy \
  --auto-scaling-group-name "$ASG_NAME" \
  --policy-name "cpu-target-50" \
  --query 'PolicyARN' \
  --output text \
  --policy-type TargetTrackingScaling \
  --target-tracking-configuration '{
    "PredefinedMetricSpecification": {
      "PredefinedMetricType": "ASGAverageCPUUtilization"
    },
    "TargetValue": 50.0
  }')
  
echo "Scaling policy: $POLICY_ARN"

echo ""
echo "🚀 Infrastructure deployed successfully!"
echo ""
echo "🌐 ALB DNS:  $ALB_DNS"
echo "🔗 URL:      http://$ALB_DNS"
echo "⚡ Health:   http://$ALB_DNS/health"
echo ""
echo "⏳ Note: Instances are starting. Wait ~2 minutes before testing."
echo "   ALB health checks need to pass before traffic is served."

# Save all resource IDs to .deploy_state
cat > "$SCRIPT_DIR/.deploy_state" << EOF
# ---- Part A ----
VPC_ID="$VPC_ID"
PUBLIC_SUBNET_1_ID="$PUBLIC_SUBNET_1_ID"
PUBLIC_SUBNET_2_ID="$PUBLIC_SUBNET_2_ID"
PRIVATE_SUBNET_1_ID="$PRIVATE_SUBNET_1_ID"
PRIVATE_SUBNET_2_ID="$PRIVATE_SUBNET_2_ID"
IGW_ID="$IGW_ID"
PUBLIC_ROUTE_TABLE_ID="$PUBLIC_ROUTE_TABLE_ID"
PUBLIC_RT_ASSOC_1_ID="$PUBLIC_RT_ASSOC_1_ID"
PUBLIC_RT_ASSOC_2_ID="$PUBLIC_RT_ASSOC_2_ID"
PRIVATE_ROUTE_TABLE_ID="$PRIVATE_ROUTE_TABLE_ID"
PRIVATE_RT_ASSOC_1_ID="$PRIVATE_RT_ASSOC_1_ID"
PRIVATE_RT_ASSOC_2_ID="$PRIVATE_RT_ASSOC_2_ID"
ALLOCATION_ID="$ALLOCATION_ID"
NAT_ID="$NAT_ID"
# ---- Part B ----
ALB_SG_ID="$ALB_SG_ID"
APP_SERVER_SG_ID="$APP_SERVER_SG_ID"
LT_ID="$LT_ID"
# ---- Part C ----
TG_ARN="$TG_ARN"
ALB_ARN="$ALB_ARN"
ALB_DNS="$ALB_DNS"
LISTENER_ARN="$LISTENER_ARN"
# ---- Part D ----
ASG_ARN="$ASG_ARN"
POLICY_ARN="$POLICY_ARN"

PART_B_DONE=true
PART_C_DONE=true
PART_D_DONE=true
EOF
}

if [ "${PART_D_DONE:-false}" = "true" ]; then
  echo "Auto Scaling Group and Scaling Policy already created"
else
  run_part_d
fi
