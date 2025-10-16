#!/bin/bash

set -e

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_ROOT/lib/common.sh"

DEMO_NAME="${1:-$DEMO_NAME}"
CLUSTER_NAME="${CLUSTER_NAME:-watt-benchmark-$(date +%s)}"
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_PROFILE="${AWS_PROFILE}"
NODE_TYPE="${NODE_TYPE:-t3.xlarge}"
NODE_COUNT="${NODE_COUNT:-2}"
DEMO_SOURCE_DIR="$PROJECT_ROOT/demos/$DEMO_NAME"
KUBE_MANIFEST="${DEMO_SOURCE_DIR}/kube.yaml"
AUTOCANNON_IMAGE="${AUTOCANNON_IMAGE:-platformatic/autocannon:latest}"
AMI_ID="${AMI_ID:-ami-07b2b18045edffe90}" # Amazon Linux 2023 arm64
AUTOCANNON_INSTANCE_TYPE="${AUTOCANNON_INSTANCE_TYPE:-t3.micro}"
AUTOCANNON_INSTANCE_ID=""
SECURITY_GROUP_ID=""

cleanup_instances() {
	if [[ -n "$AUTOCANNON_INSTANCE_ID" ]]; then
		log "Terminating autocannon instance: $AUTOCANNON_INSTANCE_ID"
		aws ec2 terminate-instances \
			--instance-ids "$AUTOCANNON_INSTANCE_ID" \
			--profile "$AWS_PROFILE" \
			--region "$AWS_REGION" >/dev/null 2>&1 || true
	fi

	if [[ -n "$CLUSTER_NAME" ]]; then
		log "Checking if cluster exists..."
		if eksctl get cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1; then
			log "Deleting EKS cluster: $CLUSTER_NAME"
			eksctl delete cluster \
				--name "$CLUSTER_NAME" \
				--region "$AWS_REGION" \
				--profile "$AWS_PROFILE" \
				--wait 2>&1 | grep -v "waiting for" || true
		else
			log "Cluster $CLUSTER_NAME does not exist, skipping deletion"
		fi
	fi

	if [[ -n "$SECURITY_GROUP_ID" ]]; then
		log "Deleting security group: $SECURITY_GROUP_ID"
		sleep 5
		aws ec2 delete-security-group \
			--group-id "$SECURITY_GROUP_ID" \
			--profile "$AWS_PROFILE" \
			--region "$AWS_REGION" >/dev/null 2>&1 || true
	fi
}

trap generic_cleanup EXIT INT TERM

validate_eks_tools() {
	log "Validating EKS tools..."

	if ! check_tool "eksctl" "Please install eksctl: https://eksctl.io/installation/"; then
		return 1
	fi

	if ! check_tool "kubectl" "Please install kubectl: https://kubernetes.io/docs/tasks/tools/"; then
		return 1
	fi

	success "EKS tools validated"
	return 0
}

validate_demo_manifests() {
	log "Validating demo manifests..."

	if [[ ! -f "$KUBE_MANIFEST" ]]; then
		error "Kubernetes manifest not found: $KUBE_MANIFEST"
		error "Expected kube.yaml in demo directory"
		return 1
	fi

	success "Demo manifests validated"
	return 0
}

create_security_group_for_autocannon() {
	log "Creating security group for autocannon instance..."

	# Get the VPC ID of the EKS cluster
	local vpc_id=$(aws eks describe-cluster \
		--name "$CLUSTER_NAME" \
		--region "$AWS_REGION" \
		--profile "$AWS_PROFILE" \
		--query 'cluster.resourcesVpcConfig.vpcId' \
		--output text)

	if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then
		error "Could not get VPC ID from EKS cluster"
		return 1
	fi

	log "Using VPC from EKS cluster: $vpc_id"

	local timestamp=$(date +%s)
	local sg_name="autocannon-sg-$timestamp"

	SECURITY_GROUP_ID=$(aws ec2 create-security-group \
		--group-name "$sg_name" \
		--description "Temporary security group for autocannon instance" \
		--vpc-id "$vpc_id" \
		--region "$AWS_REGION" \
		--query 'GroupId' \
		--output text \
		--profile "$AWS_PROFILE")

	log "Created security group: $SECURITY_GROUP_ID"
	success "Security group configured"
}

configure_node_security_for_nodeports() {
	local node_ports=$1

	log "Configuring node security groups for NodePort access..."

	# Get node security group from EKS cluster
	local node_sg=$(aws eks describe-cluster \
		--name "$CLUSTER_NAME" \
		--region "$AWS_REGION" \
		--profile "$AWS_PROFILE" \
		--query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' \
		--output text)

	if [[ -z "$node_sg" || "$node_sg" == "None" ]]; then
		error "Could not get cluster security group"
		return 1
	fi

	log "Cluster security group: $node_sg"

	# Add ingress rules for each NodePort
	IFS=',' read -ra PORTS <<< "$node_ports"
	for port in "${PORTS[@]}"; do
		log "Adding ingress rule for NodePort $port..."

		# Allow autocannon security group to access this NodePort
		aws ec2 authorize-security-group-ingress \
			--group-id "$node_sg" \
			--protocol tcp \
			--port "$port" \
			--source-group "$SECURITY_GROUP_ID" \
			--region "$AWS_REGION" \
			--profile "$AWS_PROFILE" 2>/dev/null || {
			# Rule might already exist, that's ok
			log "  (rule may already exist, continuing...)"
		}
	done

	success "Node security configured for ports: $node_ports"
}

create_eks_cluster() {
	log "Creating EKS cluster: $CLUSTER_NAME"
	log "This may take 15-20 minutes..."

	# Create cluster with public endpoint access so autocannon can reach it
	eksctl create cluster \
		--name "$CLUSTER_NAME" \
		--region "$AWS_REGION" \
		--profile "$AWS_PROFILE" \
		--node-type "$NODE_TYPE" \
		--nodes "$NODE_COUNT" \
		--nodes-min "$NODE_COUNT" \
		--nodes-max "$NODE_COUNT" \
		--managed \
		--with-oidc \
		--vpc-public-subnets \
		--external-dns-access 2>&1 | grep -E "creating|created|waiting" || true

	success "EKS cluster created: $CLUSTER_NAME"
}

wait_for_nodes() {
	log "Waiting for nodes to be ready..."

	local max_attempts=60
	local retry_delay=5

	for ((i = 1; i <= max_attempts; i++)); do
		local ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || echo "0")

		if [[ "$ready_nodes" -ge "$NODE_COUNT" ]]; then
			success "All $NODE_COUNT nodes are ready"
			return 0
		fi

		if ((i % 10 == 0)); then
			log "Still waiting for nodes... $ready_nodes/$NODE_COUNT ready (attempt $i/$max_attempts)"
		fi
		sleep "$retry_delay"
	done

	error "Nodes not ready after $((max_attempts * retry_delay)) seconds"
	return 1
}

apply_demo_manifests() {
	log "Applying demo manifests from $KUBE_MANIFEST..."

	kubectl apply -f "$KUBE_MANIFEST"

	success "Demo manifests applied"
}

wait_for_pods() {
	log "Waiting for pods to be ready..."

	local max_attempts=120
	local retry_delay=5

	for ((i = 1; i <= max_attempts; i++)); do
		# Get all pods and check if they're all running
		local pod_status=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -v "kube-system" | grep -v "Running" || echo "")

		if [[ -z "$pod_status" ]]; then
			# Check if there are any pods at all
			local pod_count=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -v "kube-system" | wc -l)
			if [[ "$pod_count" -gt 0 ]]; then
				success "All pods are running"
				kubectl get pods --all-namespaces | grep -v "kube-system"
				return 0
			fi
		fi

		if ((i % 10 == 0)); then
			log "Still waiting for pods... (attempt $i/$max_attempts)"
			kubectl get pods --all-namespaces | grep -v "kube-system" || true
		fi
		sleep "$retry_delay"
	done

	error "Pods not ready after $((max_attempts * retry_delay)) seconds"
	kubectl get pods --all-namespaces
	return 1
}

find_annotated_nodeport_services() {
	log "Finding annotated NodePort services..."

	# Find all services with the benchmark annotation
	local services=$(kubectl get services -o json | jq -r '.items[] |
		select(.metadata.annotations["benchmark.platformatic.dev/expose"] == "true") |
		select(.spec.type == "NodePort") |
		{name: .metadata.name, port: .spec.ports[0].nodePort} |
		"\(.name):\(.port)"')

	if [[ -z "$services" ]]; then
		error "No NodePort services found with annotation benchmark.platformatic.dev/expose=true"
		log "Available services:"
		kubectl get services
		return 1
	fi

	log "Found annotated services:"
	echo "$services" | while read -r svc; do
		log "  - $svc"
	done

	echo "$services"
}

get_node_private_ip() {
	log "Getting private IP of a cluster node..."

	local node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

	if [[ -z "$node_ip" ]]; then
		error "Could not get node private IP"
		kubectl get nodes -o wide
		return 1
	fi

	log "Node private IP: $node_ip"
	echo "$node_ip"
}

get_node_ports_list() {
	local services=$1
	echo "$services" | while read -r svc; do
		echo "$svc" | cut -d: -f2
	done | tr '\n' ',' | sed 's/,$//'
}

get_instance_ip() {
	aws ec2 describe-instances \
		--instance-ids "$1" \
		--region "$AWS_REGION" \
		--query 'Reservations[0].Instances[0].PublicIpAddress' \
		--profile "$AWS_PROFILE" \
		--output text
}

launch_autocannon_instance() {
	local node_ip=$1

	log "Launching autocannon EC2 instance..."

	# Get a private subnet from the EKS cluster VPC (autocannon needs to reach private node IPs)
	local vpc_id=$(aws eks describe-cluster \
		--name "$CLUSTER_NAME" \
		--region "$AWS_REGION" \
		--profile "$AWS_PROFILE" \
		--query 'cluster.resourcesVpcConfig.vpcId' \
		--output text)

	# Use private subnet since nodes are on private IPs
	local subnet_id=$(aws ec2 describe-subnets \
		--filters "Name=vpc-id,Values=$vpc_id" \
		--region "$AWS_REGION" \
		--profile "$AWS_PROFILE" \
		--query 'Subnets[0].SubnetId' \
		--output text)

	if [[ -z "$subnet_id" || "$subnet_id" == "None" ]]; then
		error "Could not find subnet in VPC"
		return 1
	fi

	log "Using subnet: $subnet_id"

	# Create user data script for autocannon instance
	IFS='' read -r -d '' ac_user_script <<EOF || true
#!/bin/bash
set -x

yum update -y
yum install -y docker
systemctl start docker
systemctl enable docker

# Wait for docker to be ready
sleep 10

# Pull the pre-built autocannon image
echo 'Pulling autocannon image'
docker pull $AUTOCANNON_IMAGE

# Run autocannon benchmark with node IP
echo 'Starting benchmark against node $node_ip'
docker run -e TARGET_URL=$node_ip -e DEMO_NAME=$DEMO_NAME $AUTOCANNON_IMAGE

echo 'Benchmark completed - instance will terminate'
EOF

	local ac_user_data=$(echo -n "$ac_user_script" | base64 -w0)

	AUTOCANNON_INSTANCE_ID=$(aws ec2 run-instances \
		--image-id "$AMI_ID" \
		--count 1 \
		--instance-type "$AUTOCANNON_INSTANCE_TYPE" \
		--user-data "${ac_user_data}" \
		--subnet-id "$subnet_id" \
		--security-group-ids "$SECURITY_GROUP_ID" \
		--tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=benchmark-autocannon}]" \
		--region "$AWS_REGION" \
		--query 'Instances[0].InstanceId' \
		--output text \
		--profile "$AWS_PROFILE")

	success "Autocannon instance launched: $AUTOCANNON_INSTANCE_ID"
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
			--region "$AWS_REGION" \
			--query 'Output' \
			--output text \
			--latest \
			--profile "$AWS_PROFILE")

		# Show only new output
		if [[ -n "$current_output" && "$current_output" != "$previous_output" ]]; then
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
	show_benchmark_config "$DEMO_NAME" "AWS EKS"

	if ! validate_aws_tools || ! validate_common_tools || ! validate_eks_tools; then
		error "Tool validation failed"
		exit 1
	fi

	if ! validate_required_vars "AWS_PROFILE" "DEMO_NAME"; then
		exit 1
	fi

	if ! validate_demo_manifests; then
		exit 1
	fi

	create_eks_cluster

	# Update kubeconfig
	log "Updating kubeconfig..."
	eksctl utils write-kubeconfig \
		--cluster "$CLUSTER_NAME" \
		--region "$AWS_REGION" \
		--profile "$AWS_PROFILE"

	wait_for_nodes
	apply_demo_manifests
	wait_for_pods

	# Find annotated NodePort services
	local services=$(find_annotated_nodeport_services)

	if [[ -z "$services" ]]; then
		error "Could not find annotated NodePort services"
		exit 1
	fi

	# Get node private IP
	local node_ip=$(get_node_private_ip)

	if [[ -z "$node_ip" ]]; then
		error "Could not get node IP"
		exit 1
	fi

	# Get comma-separated list of NodePorts for security group configuration
	local node_ports=$(get_node_ports_list "$services")

	log "Services will be accessible at: $node_ip"
	log "NodePorts: $node_ports"

	# Create security group for autocannon instance (must be in same VPC as EKS)
	create_security_group_for_autocannon

	# Configure node security groups to allow NodePort traffic from autocannon
	configure_node_security_for_nodeports "$node_ports"

	# Launch autocannon EC2 instance with node IP
	launch_autocannon_instance "$node_ip"

	log "Waiting for autocannon instance to be running..."
	aws ec2 wait instance-running \
		--instance-ids "$AUTOCANNON_INSTANCE_ID" \
		--region "$AWS_REGION" \
		--profile "$AWS_PROFILE"

	# Monitor autocannon output
	monitor_autocannon "$AUTOCANNON_INSTANCE_ID"

	success "Benchmark orchestration completed!"
}

main "$@"
