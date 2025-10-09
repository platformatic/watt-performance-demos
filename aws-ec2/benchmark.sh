#!/bin/bash

set -e

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_ROOT/lib/common.sh"

DEMO_NAME="${1:-$DEMO_NAME}"
AMI_ID="${AMI_ID:-ami-0010b929226fe8eba}" # Amazon Linux 2023
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
AWS_PROFILE="${AWS_PROFILE}"
DEMO_PORTS="${DEMO_PORTS:-3000-3004}" # Ports to open for demo services
DEMO_IMAGE="${DEMO_IMAGE:-platformatic/pm2-vs-watt:latest}"
CANNON_IMAGE="${AUTOCANNON_IMAGE:-platformatic/autocannon:latest}"

DEMO_INSTANCE_ID=""
AUTOCANNON_INSTANCE_ID=""
SECURITY_GROUP_ID=""
VPC_ID=""

cleanup_instances() {
	if [[ -n "$DEMO_INSTANCE_ID" ]]; then
		log "Terminating demo instance: $DEMO_INSTANCE_ID"
		aws ec2 terminate-instances \
			--instance-ids "$DEMO_INSTANCE_ID" \
			--profile $AWS_PROFILE >/dev/null 2>&1 || true
	fi

	if [[ -n "$AUTOCANNON_INSTANCE_ID" ]]; then
		log "Terminating autocannon instance: $AUTOCANNON_INSTANCE_ID"
		aws ec2 terminate-instances \
			--instance-ids "$AUTOCANNON_INSTANCE_ID" \
			--profile $AWS_PROFILE >/dev/null 2>&1 || true
	fi

	if [[ -n "$SECURITY_GROUP_ID" ]]; then
		log "Deleting security group: $SECURITY_GROUP_ID"
		# Wait a bit for instances to detach from security group
		sleep 5
		aws ec2 delete-security-group \
			--group-id "$SECURITY_GROUP_ID" \
			--profile $AWS_PROFILE >/dev/null 2>&1 || true
	fi
}

trap generic_cleanup EXIT INT TERM

create_security_group() {
	log "Creating security group for benchmark..."

	VPC_ID=$(aws ec2 describe-vpcs \
		--filters "Name=is-default,Values=true" \
		--query 'Vpcs[0].VpcId' \
		--output text \
		--profile $AWS_PROFILE)

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
		--profile $AWS_PROFILE)

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
			--profile $AWS_PROFILE >/dev/null

	else
		# Comma-separated ports (e.g., "3000,3001,3002")
		IFS=',' read -ra PORTS <<<"$DEMO_PORTS"
		for port in "${PORTS[@]}"; do
			port=$(echo "$port" | xargs) # Trim whitespace
			log "Opening port: $port"

			aws ec2 authorize-security-group-ingress \
				--group-id "$SECURITY_GROUP_ID" \
				--protocol tcp \
				--port "$port" \
				--cidr 0.0.0.0/0 \
				--profile $AWS_PROFILE >/dev/null
		done
	fi

	success "Security group configured with ports: $DEMO_PORTS"
}

launch_instance() {
	local name=$1
	local user_data=$2

	local instance_id
	local iam_param=""

	instance_id=$(aws ec2 run-instances \
		--image-id "$AMI_ID" \
		--count 1 \
		--instance-type "$INSTANCE_TYPE" \
		--user-data "${user_data}" \
		--security-group-ids "$SECURITY_GROUP_ID" \
		$iam_param \
		--tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=benchmark-$name}]" \
		--query 'Instances[0].InstanceId' \
		--output text \
		--profile $AWS_PROFILE)

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

parse_console_output() {
	local temp_file=$(mktemp)
	cat >"$temp_file"

	local start_line=$(grep -n "Starting benchmark" "$temp_file" |
		grep -v '+ echo' |
		tail -1 |
		cut -d: -f1)

	local end_line=$(tail -n +$start_line "$temp_file" |
		grep -n "Benchmark completed" |
		grep -v '+ echo' |
		head -1 |
		cut -d: -f1)
	end_line=$((start_line + end_line - 1))

	sed -n "${start_line},${end_line}p" "$temp_file" |
		sed -E 's/^\[[^]]+\] cloud-init\[[0-9]+\]: //' |
		grep -v '^+ ' |
		grep -Ev 'docker run|entered blocking|entered disabled|entered promiscuous|left promiscuous|renamed from|link becomes ready|entered forwarding'

	rm -f "$temp_file"
}

monitor_autocannon() {
	local instance_id=$1
	local previous_output=""
	local current_output=""
	local all_output=""

	log "Monitoring autocannon instance console output..."
	log "Waiting for benchmark to complete (this may take a few minutes)..."

	while true; do
		current_output=$(aws ec2 get-console-output \
			--instance-id "$instance_id" \
			--query 'Output' \
			--output text \
			--latest \
			--profile $AWS_PROFILE)

		# Show only new output
		if [[ -n "$current_output" && "$current_output" != "$previous_output" ]]; then
			# Extract the new lines by comparing with previous output
			local new_output=""
			if [[ -n "$previous_output" ]]; then
				new_output=$(echo "$current_output" | grep -v -F "$previous_output" || true)
			else
				new_output="$current_output"
			fi

			previous_output="$current_output"
			all_output+="$current_output"
		fi

		# Check if benchmark completed
		if echo "$current_output" | grep -q "Benchmark completed"; then
			echo "$all_output" | parse_console_output
			success "Benchmark execution completed!"
			break
		fi

		sleep 10
	done
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

	create_security_group

	log "Creating demo instance..."
	local demo_cmd
	demo_cmd=$(get_demo_command "$DEMO_IMAGE" "$DEMO_PORTS")
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

	log "Creating autocannon instance with target $DEMO_IP on ports $DEMO_PORTS"

	IFS='' read -r -d '' ac_user_script <<EOF || true
#!/bin/bash
set -x

yum update -y
yum install -y docker
systemctl start docker
systemctl enable docker

# Wait for docker to be ready
sleep 10

# Pull the pre-built autocannon image from GitHub Container Registry
echo 'Pulling autocannon image'
docker pull $CANNON_IMAGE

# Run autocannon benchmark with demo URL and redirect output to log file
echo 'Starting benchmark against http://$DEMO_IP'
docker run -e TARGET_URL=http://$DEMO_IP -e DEMO_NAME=$DEMO_NAME $CANNON_IMAGE

echo 'Benchmark completed - instance will terminate'
EOF

	ac_user_data=$(echo -n "$ac_user_script" | base64 -w0)
	AUTOCANNON_INSTANCE_ID=$(launch_instance "autocannon" $ac_user_data)

	log "Autocannon instance: $AUTOCANNON_INSTANCE_ID"

	log "Waiting for autocannon instance to be running..."
	aws ec2 wait instance-running --instance-ids "$AUTOCANNON_INSTANCE_ID" --profile $AWS_PROFILE

	monitor_autocannon "$AUTOCANNON_INSTANCE_ID"

	success "Benchmark orchestration completed!"
}

main "$@"
