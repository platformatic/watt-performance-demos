#!/bin/bash

set -e

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_ROOT/lib/common.sh"

AMI_NAME="${AMI_NAME:-al2023-ami-kernel-default-x86_64}"  # Amazon Linux 2023
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
AWS_PROFILE="${AWS_PROFILE}"
DEMO_PORTS="${DEMO_PORTS:-3000-3004}"  # Ports to open for demo services
DEMO_IMAGE="${DEMO_IMAGE:-platformatic/pm2-vs-watt:latest}"

DEMO_INSTANCE_ID=""
AUTOCANNON_INSTANCE_ID=""
SECURITY_GROUP_ID=""
VPC_ID=""

cleanup_instances() {
    if [[ -n "$DEMO_INSTANCE_ID" ]]; then
        log "Terminating demo instance: $DEMO_INSTANCE_ID"
        aws ec2 terminate-instances --instance-ids "$DEMO_INSTANCE_ID" --profile $AWS_PROFILE > /dev/null 2>&1 || true
    fi

    if [[ -n "$AUTOCANNON_INSTANCE_ID" ]]; then
        log "Terminating autocannon instance: $AUTOCANNON_INSTANCE_ID"
        aws ec2 terminate-instances --instance-ids "$AUTOCANNON_INSTANCE_ID" --profile $AWS_PROFILE > /dev/null 2>&1 || true
    fi

    if [[ -n "$SECURITY_GROUP_ID" ]]; then
        log "Deleting security group: $SECURITY_GROUP_ID"
        # Wait a bit for instances to detach from security group
        sleep 5
        aws ec2 delete-security-group --group-id "$SECURITY_GROUP_ID" --profile $AWS_PROFILE > /dev/null 2>&1 || true
    fi

    # TODO detach SSM policies
}

trap generic_cleanup EXIT INT TERM

setup_ssm_user_permissions() {
    log "Setting up SSM user permissions..."

    local policy_name="BenchmarkSSMUserPolicy"
    local user_arn
    user_arn=$(aws sts get-caller-identity --query 'Arn' --output text --profile $AWS_PROFILE)
    local user_name="${user_arn##*/}"

    # SSM policy
    local policy_document='{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": [
                    "ssm:DescribeInstanceInformation",
                    "ssm:StartSession",
                    "ssm:TerminateSession",
                    "ssm:ResumeSession",
                    "ssm:DescribeSessions",
                    "ssm:GetConnectionStatus",
                    "ssm:SendCommand",
                    "ssm:GetCommandInvocation",
                    "ssm:ListCommands",
                    "ssm:ListCommandInvocations"
                ],
                "Resource": "*"
            }
        ]
    }'

    local policy_arn
    policy_arn=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='$policy_name'].Arn" --output text --profile $AWS_PROFILE)

    if [[ -z "$policy_arn" ]]; then
        log "Creating SSM user policy..."
        policy_arn=$(aws iam create-policy \
            --policy-name "$policy_name" \
            --policy-document "$policy_document" \
            --description "Policy for benchmark script to use SSM Session Manager" \
            --query 'Policy.Arn' \
            --output text \
            --profile $AWS_PROFILE)
        log "Policy created: $policy_arn"
    else
        log "Updating existing SSM user policy..."
        local default_version
        default_version=$(aws iam get-policy --policy-arn "$policy_arn" --query 'Policy.DefaultVersionId' --output text --profile $AWS_PROFILE)

        aws iam create-policy-version \
            --policy-arn "$policy_arn" \
            --policy-document "$policy_document" \
            --set-as-default \
            --profile $AWS_PROFILE > /dev/null 2>&1 || true

        log "Policy updated: $policy_arn"
    fi

    if ! aws iam list-attached-user-policies --user-name "$user_name" --profile $AWS_PROFILE | grep -q "$policy_name"; then
        log "Attaching SSM policy to user $user_name..."
        aws iam attach-user-policy \
            --user-name "$user_name" \
            --policy-arn "$policy_arn" \
            --profile $AWS_PROFILE
        log "Policy attached - waiting for IAM propagation..."
        sleep 10
    fi

    success "SSM user permissions ready"
}

setup_ssm_role() {
    log "Setting up SSM IAM role for instances..."

    local role_name="SSMDefaultRole"
    local profile_name="SSMDefaultRole"

    if ! aws iam get-role --role-name "$role_name" --profile $AWS_PROFILE > /dev/null 2>&1; then
        log "Creating IAM role for SSM..."

        local trust_policy='{
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Principal": {"Service": "ec2.amazonaws.com"},
                "Action": "sts:AssumeRole"
            }]
        }'

        aws iam create-role \
            --role-name "$role_name" \
            --assume-role-policy-document "$trust_policy" \
            --profile $AWS_PROFILE > /dev/null

        aws iam attach-role-policy \
            --role-name "$role_name" \
            --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" \
            --profile $AWS_PROFILE

        log "IAM role created"
    fi

    if ! aws iam get-instance-profile --instance-profile-name "$profile_name" --profile $AWS_PROFILE > /dev/null 2>&1; then
        log "Creating instance profile..."

        aws iam create-instance-profile \
            --instance-profile-name "$profile_name" \
            --profile $AWS_PROFILE > /dev/null

        aws iam add-role-to-instance-profile \
            --instance-profile-name "$profile_name" \
            --role-name "$role_name" \
            --profile $AWS_PROFILE

        sleep 10
        log "Instance profile created"
    fi

    success "SSM IAM role ready"
}

create_security_group() {
    log "Creating security group for benchmark..."

    # TODO remove regions, let aws choose

    VPC_ID=$(aws ec2 describe-vpcs \
        --filters "Name=is-default,Values=true" \
        --query 'Vpcs[0].VpcId' \
        --output text \
        --profile $AWS_PROFILE \
        --region us-west-2)

    if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
        error "No default VPC found. Please create a VPC first."
        exit 1
    fi

    log "Using VPC: $VPC_ID"

    local timestamp=$(date +%s)
    local sg_name="benchmark-sg-$timestamp"

    SECURITY_GROUP_ID=$(aws ec2 create-security-group \
        --group-name "$sg_name" \
        --description "Temporary security group for benchmark (ports $DEMO_PORTS)" \
        --vpc-id "$VPC_ID" \
        --query 'GroupId' \
        --output text \
        --profile $AWS_PROFILE \
        --region us-west-2)

    log "Created security group: $SECURITY_GROUP_ID"

    # Parse DEMO_PORTS and add ingress rules
    # Supports both "3000-3004" (range) and "3000,3001,3002" (comma-separated)
    if [[ "$DEMO_PORTS" =~ ^[0-9]+-[0-9]+$ ]]; then
        # Port range (e.g., "3000-3004")
        local from_port="${DEMO_PORTS%-*}"
        local to_port="${DEMO_PORTS#*-}"
        log "Opening port range: $from_port-$to_port"

        aws ec2 authorize-security-group-ingress \
            --group-id "$SECURITY_GROUP_ID" \
            --protocol tcp \
            --port "$from_port-$to_port" \
            --cidr 0.0.0.0/0 \
            --profile $AWS_PROFILE \
            --region us-west-2 > /dev/null

    else
        # Comma-separated ports (e.g., "3000,3001,3002")
        IFS=',' read -ra PORTS <<< "$DEMO_PORTS"
        for port in "${PORTS[@]}"; do
            port=$(echo "$port" | xargs)  # Trim whitespace
            log "Opening port: $port"

            aws ec2 authorize-security-group-ingress \
                --group-id "$SECURITY_GROUP_ID" \
                --protocol tcp \
                --port "$port" \
                --cidr 0.0.0.0/0 \
                --profile $AWS_PROFILE \
                --region us-west-2 > /dev/null
        done
    fi

    success "Security group configured with ports: $DEMO_PORTS"
}

launch_instance() {
    local name=$1
    local user_data=$2

    local instance_id
    instance_id=$(aws ec2 run-instances \
        --image-id "ami-0010b929226fe8eba" \
        --count 1 \
        --instance-type "$INSTANCE_TYPE" \
        --user-data "${user_data}" \
        --security-group-ids "$SECURITY_GROUP_ID" \
        --iam-instance-profile Name=SSMDefaultRole \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=benchmark-$name}]" \
        --query 'Instances[0].InstanceId' \
        --output text \
        --profile $AWS_PROFILE \
        --region us-west-2)

    log "Launching $name instance..."
    echo "$instance_id"
}

get_instance_ip() {
    aws ec2 describe-instances \
        --instance-ids "$1" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --profile $AWS_PROFILE \
        --output text
}


wait_for_ssm() {
    local instance_id=$1
    local max_attempts=60
    local retry_delay=5

    log "Waiting for SSM agent to be ready on $instance_id..."

    for ((i=1; i<=max_attempts; i++)); do
        local status
        status=$(aws ssm describe-instance-information \
            --filters "Key=InstanceIds,Values=$instance_id" \
            --query 'InstanceInformationList[0].PingStatus' \
            --output text \
            --profile $AWS_PROFILE \
            --region us-west-2 2>/dev/null || echo "")

        if [[ "$status" == "Online" ]]; then
            success "SSM agent is ready"
            return 0
        fi

        if ((i % 10 == 0)); then
            log "Still waiting for SSM... attempt $i/$max_attempts"
        fi
        sleep "$retry_delay"
    done

    error "SSM agent not ready after $((max_attempts * retry_delay)) seconds"
    return 1
}

# TODO fix command error
# Error: "docker logs" requires exactly 1 argument
monitor_autocannon_ssm() {
    local instance_id=$1

    log "Monitoring autocannon output via SSM..."

    if ! wait_for_ssm "$instance_id"; then
        error "Cannot connect via SSM"
        return 1
    fi

    log "Streaming benchmark results..."
    echo "=== AUTOCANNON OUTPUT ==="

    local command_id
    command_id=$(aws ssm send-command \
        --instance-ids "$instance_id" \
        --document-name "AWS-RunShellScript" \
        --parameters 'commands=["timeout 600 docker logs -f $(docker ps -q) 2>&1 || true"]' \
        --query 'Command.CommandId' \
        --output text \
        --profile $AWS_PROFILE \
        --region us-west-2)

    log "Command ID: $command_id"

    sleep 5

    local previous_output=""
    local max_attempts=120  # 10 minutes
    local attempt=0

    while ((attempt < max_attempts)); do
        local output
        output=$(aws ssm get-command-invocation \
            --command-id "$command_id" \
            --instance-id "$instance_id" \
            --query 'StandardOutputContent' \
            --output text \
            --profile $AWS_PROFILE \
            --region us-west-2 2>/dev/null || echo "")

        # Print only new output
        if [[ -n "$output" && "$output" != "$previous_output" ]]; then
            # Print only the new lines
            if [[ -n "$previous_output" ]]; then
                echo "$output" | tail -c +$((${#previous_output} + 1))
            else
                echo "$output"
            fi
            previous_output="$output"
        fi

        local status
        status=$(aws ssm get-command-invocation \
            --command-id "$command_id" \
            --instance-id "$instance_id" \
            --query 'Status' \
            --output text \
            --profile $AWS_PROFILE \
            --region us-west-2 2>/dev/null || echo "InProgress")

        if [[ "$status" == "Success" ]] || [[ "$status" == "Failed" ]] || [[ "$status" == "TimedOut" ]] || [[ "$status" == "Cancelled" ]]; then
            output=$(aws ssm get-command-invocation \
                --command-id "$command_id" \
                --instance-id "$instance_id" \
                --query 'StandardOutputContent' \
                --output text \
                --profile $AWS_PROFILE \
                --region us-west-2 2>/dev/null || echo "")

            if [[ -n "$output" && "$output" != "$previous_output" ]]; then
                if [[ -n "$previous_output" ]]; then
                    echo "$output" | tail -c +$((${#previous_output} + 1))
                else
                    echo "$output"
                fi
            fi

            if [[ "$status" == "Success" ]]; then
                break
            else
                warning "Command ended with status: $status"
                break
            fi
        fi

        sleep 5
        ((attempt++))
    done

    echo "========================="
    success "Autocannon benchmark completed"
}

main() {
    show_benchmark_config "$DEMO_IMAGE" "AWS EC2"

    if ! validate_aws_tools || ! validate_common_tools; then
        error "Tool validation failed"
        exit 1
    fi
    if ! validate_required_vars "AWS_PROFILE"; then
        exit 1
    fi

    setup_ssm_user_permissions
    setup_ssm_role
    create_security_group

    log "Creating demo instance..."
    local demo_cmd
    demo_cmd=$(get_demo_command "$DEMO_IMAGE")
    log "Demo command: $demo_cmd"

    IFS='' read -r -d '' demo_user_script <<EOF || true
#!/bin/bash
yum update -y
yum install -y docker
systemctl start docker
systemctl enable docker

# Pull demo image
docker pull $DEMO_IMAGE

# Wait for docker to be ready
sleep 5

# Run demo service - $DEMO_IMAGE type
$demo_cmd

# Wait for service to start
sleep 10
echo 'Demo service started with type: $DEMO_IMAGE'
EOF

    demo_user_data=$(echo -n "$demo_user_script" | base64 -w0)
    DEMO_INSTANCE_ID=$(launch_instance "demo" $demo_user_data)

    log "Demo instance: $DEMO_INSTANCE_ID"
    
    log "Waiting for demo instance to be running..."
    aws ec2 wait instance-running --instance-ids "$DEMO_INSTANCE_ID" --profile $AWS_PROFILE
    
    DEMO_IP=$(get_instance_ip "$DEMO_INSTANCE_ID")
    log "Demo instance IP: $DEMO_IP"
    wait_for_http "$DEMO_IP" 3000
    
    log "Creating autocannon instance with target $DEMO_IP:$DEMO_PORT"
    
    IFS='' read -r -d '' ac_user_script <<EOF || true
#!/bin/bash
yum update -y
yum install -y docker
systemctl start docker
systemctl enable docker

# Wait for docker to be ready
sleep 10

# Pull the pre-built autocannon image from GitHub Container Registry
echo 'Pulling autocannon image'
docker pull plfmzugm/autocannon:0.0.1-alpha.1

# Run autocannon benchmark with demo URL
echo 'Starting benchmark against http://$DEMO_IP:$DEMO_PORT'
docker run --rm -e TARGET_URL=http://$DEMO_IP:$DEMO_PORT plfmzugm/autocannon:0.0.1-alpha.1

echo 'Benchmark completed - instance will terminate'
EOF

    ac_user_data=$(echo -n "$ac_user_script" | base64 -w0)
    AUTOCANNON_INSTANCE_ID=$(launch_instance "autocannon" $ac_user_data)

    log "Autocannon instance: $AUTOCANNON_INSTANCE_ID"
    
    log "Waiting for autocannon instance to be running..."
    aws ec2 wait instance-running --instance-ids "$AUTOCANNON_INSTANCE_ID" --profile $AWS_PROFILE

    monitor_autocannon_ssm "$AUTOCANNON_INSTANCE_ID"

    success "Benchmark orchestration completed!"
}

main "$@"
