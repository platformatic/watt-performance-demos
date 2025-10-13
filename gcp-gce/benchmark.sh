#!/bin/bash

set -e

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_ROOT/lib/common.sh"

DEMO_NAME="${1:-$DEMO_NAME}"
IMAGE_FAMILY="${IMAGE_FAMILY:-ubuntu-2204-lts}"
IMAGE_PROJECT="${IMAGE_PROJECT:-ubuntu-os-cloud}"
MACHINE_TYPE="${MACHINE_TYPE:-n2-standard-8}"
GCP_PROJECT="${GCP_PROJECT}"
GCP_ZONE="${GCP_ZONE:-us-central1-a}"
CANNON_IMAGE="${AUTOCANNON_IMAGE:-platformatic/autocannon:latest}"

DEMO_PORTS="3000-3002"
DEMO_INSTANCE_NAME=""
DEMO_SOURCE_DIR="$PROJECT_ROOT/demos/$DEMO_NAME"
AUTOCANNON_INSTANCE_NAME=""
FIREWALL_RULE_NAME=""
NETWORK_TAG="benchmark-$(date +%s)"

cleanup_instances() {
	if [[ -n "$DEMO_INSTANCE_NAME" ]]; then
		log "Deleting demo instance: $DEMO_INSTANCE_NAME"
		gcloud compute instances delete "$DEMO_INSTANCE_NAME" \
			--zone="$GCP_ZONE" \
			--project="$GCP_PROJECT" \
			--quiet >/dev/null 2>&1 || true
	fi

	if [[ -n "$AUTOCANNON_INSTANCE_NAME" ]]; then
		log "Deleting autocannon instance: $AUTOCANNON_INSTANCE_NAME"
		gcloud compute instances delete "$AUTOCANNON_INSTANCE_NAME" \
			--zone="$GCP_ZONE" \
			--project="$GCP_PROJECT" \
			--quiet >/dev/null 2>&1 || true
	fi

	if [[ -n "$FIREWALL_RULE_NAME" ]]; then
		log "Deleting firewall rule: $FIREWALL_RULE_NAME"
		# Wait a bit for instances to be deleted
		sleep 5
		gcloud compute firewall-rules delete "$FIREWALL_RULE_NAME" \
			--project="$GCP_PROJECT" \
			--quiet >/dev/null 2>&1 || true
	fi
}

trap generic_cleanup EXIT INT TERM

create_firewall_rule() {
	log "Creating firewall rule for benchmark..."

	FIREWALL_RULE_NAME="benchmark-rule-$(date +%s)"

	# Parse DEMO_PORTS and create appropriate firewall rules
	# Supports both "3000-3002" (range) and "3000,3001,3002" (comma-separated)
	local ports_arg
	if [[ "$DEMO_PORTS" =~ ^[0-9]+-[0-9]+$ ]]; then
		# Port range (e.g., "3000-3002")
		ports_arg="$DEMO_PORTS"
		log "Opening port range: $DEMO_PORTS"
	else
		# Comma-separated ports (e.g., "3000,3001,3002")
		ports_arg="$DEMO_PORTS"
		log "Opening ports: $DEMO_PORTS"
	fi

	gcloud compute firewall-rules create "$FIREWALL_RULE_NAME" \
		--allow="tcp:${ports_arg}" \
		--source-ranges="0.0.0.0/0" \
		--target-tags="$NETWORK_TAG" \
		--project="$GCP_PROJECT" \
		--quiet

	success "Firewall rule configured: $FIREWALL_RULE_NAME (ports: $DEMO_PORTS)"
}

launch_instance() {
	local name=$1
	local startup_script=$2

	log "Launching $name instance..."

	local full_instance_name="benchmark-$name-$(date +%s)"

	gcloud compute instances create "$full_instance_name" \
		--image-family="$IMAGE_FAMILY" \
		--image-project="$IMAGE_PROJECT" \
		--machine-type="$MACHINE_TYPE" \
		--zone="$GCP_ZONE" \
		--tags="$NETWORK_TAG" \
		--metadata="startup-script=${startup_script}" \
		--project="$GCP_PROJECT" \
		--quiet

	echo "$full_instance_name"
}

get_instance_ip() {
	gcloud compute instances describe "$1" \
		--zone="$GCP_ZONE" \
		--project="$GCP_PROJECT" \
		--format='get(networkInterfaces[0].accessConfigs[0].natIP)'
}

parse_console_output() {
	local temp_file=$(mktemp)
	cat >"$temp_file"

	local start_line=$(grep -n "Starting benchmark" "$temp_file" |
		tail -1 |
		cut -d: -f1)

	local end_line=$(tail -n +$start_line "$temp_file" |
		grep -n "Benchmark completed" |
		head -1 |
		cut -d: -f1)
	end_line=$((start_line + end_line - 1))

	sed -n "${start_line},${end_line}p" "$temp_file" |
		grep -v '^+ ' |
		grep -Ev 'docker run|Started Google|Started google|Reached target|Stopped target|Started Run|Started startup-script|Finished running startup-script'

	rm -f "$temp_file"
}

monitor_autocannon() {
	local instance_name=$1
	local previous_output=""
	local current_output=""
	local all_output=""

	log "Monitoring autocannon instance serial console output..."
	log "Waiting for benchmark to complete (this may take a few minutes)..."

	while true; do
		current_output=$(gcloud compute instances get-serial-port-output "$instance_name" \
			--zone="$GCP_ZONE" \
			--project="$GCP_PROJECT" 2>/dev/null || true)

		# Show only new output
		if [[ -n "$current_output" && "$current_output" != "$previous_output" ]]; then
			previous_output="$current_output"
			all_output="$current_output"
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

validate_gcp_tools() {
	log "Validating GCP tools..."

	if ! check_tool "gcloud" "Please install Google Cloud SDK: https://cloud.google.com/sdk/docs/install"; then
		return 1
	fi

	success "GCP tools validated"
	return 0
}

main() {
	show_benchmark_config "$DEMO_NAME" "GCP GCE"

	if ! validate_gcp_tools || ! validate_common_tools; then
		error "Tool validation failed"
		exit 1
	fi
	if ! validate_required_vars "GCP_PROJECT"; then
		exit 1
	fi

	create_firewall_rule

	log "Creating demo instance..."
	local compose_location
	compose_location="/docker-compose.yml"
	local demo_cmd
	demo_cmd=$(get_demo_command 2 $compose_location)
	log "Demo command: $demo_cmd"

	local demo_docker_compose
	demo_docker_compose=$(cat "$DEMO_SOURCE_DIR/docker-compose.yml")

	IFS='' read -r -d '' demo_startup_script <<EOF || true
#!/bin/bash
set -e

# Update and install Docker
apt-get update
apt-get install -y docker.io docker-compose-v2

# Start Docker
systemctl start docker
systemctl enable docker

# Verify installation
docker compose version

# Write docker-compose file
cat > $compose_location <<'COMPOSE_EOF'
$demo_docker_compose
COMPOSE_EOF

cat $compose_location

# Run demo service - $DEMO_NAME type
$demo_cmd

# Wait for service to start
sleep 5
echo 'Demo service started with type: $DEMO_NAME'
EOF

	DEMO_INSTANCE_NAME=$(launch_instance "demo" "$demo_startup_script")

	log "Demo instance: $DEMO_INSTANCE_NAME"

	log "Waiting for demo instance to be running..."
	gcloud compute instances describe "$DEMO_INSTANCE_NAME" \
		--zone="$GCP_ZONE" \
		--project="$GCP_PROJECT" >/dev/null

	DEMO_IP=$(get_instance_ip "$DEMO_INSTANCE_NAME")
	log "Demo instance IP: $DEMO_IP"
	wait_for_http "$DEMO_IP" 3000

	log "Creating autocannon instance with target $DEMO_IP on ports $DEMO_PORTS"

	IFS='' read -r -d '' ac_startup_script <<EOF || true
#!/bin/bash
set -x

# Update and install Docker
apt-get update
apt-get install -y docker.io

# Start Docker
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

	AUTOCANNON_INSTANCE_NAME=$(launch_instance "autocannon" "$ac_startup_script")

	log "Autocannon instance: $AUTOCANNON_INSTANCE_NAME"

	log "Waiting for autocannon instance to be running..."
	gcloud compute instances describe "$AUTOCANNON_INSTANCE_NAME" \
		--zone="$GCP_ZONE" \
		--project="$GCP_PROJECT" >/dev/null

	monitor_autocannon "$AUTOCANNON_INSTANCE_NAME"

	success "Benchmark orchestration completed!"
}

main "$@"
