# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a multi-cloud benchmarking framework that compares PM2 vs Platformatic Watt performance across different cloud providers. The architecture is designed for extensibility - adding new cloud providers or demos follows a consistent pattern.

## Architecture

The repository uses a three-layer architecture:

1. **Common Functions Library** (`lib/common.sh`) - Shared bash functions for logging, tool validation, HTTP health checks, and cleanup across all cloud providers
2. **Demos** (`demos/`) - Self-contained performance demo applications with their own Docker images
3. **Cloud Provider Orchestration** (`aws-ec2/`, future: `gcp-gce/`, etc.) - Provider-specific `benchmark.sh` scripts that orchestrate instance creation, benchmarking, and cleanup

### Key Design Patterns

- Each cloud provider directory implements a `benchmark.sh` that sources `lib/common.sh` and defines its own `cleanup_instances()` function
- Demos are packaged as Docker images and run via:
  - **docker-compose** on cloud instances (EC2)
  - **Kubernetes manifests** in managed clusters (EKS)
- The autocannon load testing tool runs in a separate instance/container to simulate realistic network conditions
- Security groups/firewalls and clusters are created dynamically and cleaned up automatically via trap handlers

## Common Commands

### Running Benchmarks

```bash
# AWS EC2 benchmark (uses docker-compose)
cd aws-ec2
AWS_PROFILE=<profile> DEMO_NAME=pm2-vs-watt ./benchmark.sh

# AWS EKS benchmark (uses Kubernetes)
cd aws-eks
AWS_PROFILE=<profile> DEMO_NAME=k8s-next-watt ./benchmark.sh
```

### Building Docker Images

```bash
# Build demo image
cd demos/pm2-vs-watt
docker build -t platformatic/pm2-vs-watt:latest .

# Build autocannon image
docker build -f lib/Dockerfile.autocannon -t platformatic/autocannon:latest .
```

### Local Development

```bash
# Run pm2-vs-watt demo locally
cd demos/pm2-vs-watt
docker compose up

# Run benchmark against local demo
npm run bench        # Single worker benchmark
npm run bench-scale  # Multi-worker benchmark
```

## Demo Configuration

Demos can be configured in two ways depending on the deployment target:

### Docker Compose (EC2)
Demos are configured via `docker-compose.yml` with environment variables:
- `SCRIPT_NAME` - The npm script to run (e.g., `pm2r-start`, `watt-start`, `cluster-start`)
- `WORKERS` - Number of worker processes/threads
- Resource reservations (CPUs, memory) via docker compose deploy section

The demo's `entrypoint.sh` executes `npm run $SCRIPT_NAME` to start the appropriate server configuration.

### Kubernetes (EKS)
Demos provide a `kube.yaml` manifest with:
- **Deployment(s)** (required) - Application workload with container(s)
- **NodePort Service(s)** (required) - Services marked for benchmarking:
  - Must have `type: NodePort`
  - Must include annotation `benchmark.platformatic.dev/expose: "true"`
  - Must specify explicit `nodePort` values (user-controlled)
  - Port numbers should match docker-compose.yml for consistency
- Resource limits/requests in container spec
- Replica count for horizontal scaling

**Annotation-based discovery**: Script finds all services with `benchmark.platformatic.dev/expose: "true"` and configures security groups for the specified NodePorts. Autocannon accesses services via node private IP + NodePort.

**Health checks**: The autocannon Docker container includes built-in health check logic that runs before benchmarks:
- The `SERVICE_PORTS` environment variable (comma-separated list) specifies which ports to check
- `lib/dockerfile-entrypoint.sh` performs HTTP health checks for each service
- Uses curl to verify services are accessible from within the VPC
- Retries with timeout (60 attempts × 5 second delay = 5 minutes max)
- Only proceeds to benchmarking once all services respond with HTTP 200

## Cloud Provider Implementation Guide

### VM-Based Implementation (EC2-style)

When adding a VM-based cloud provider (e.g., `gcp-gce/`):

1. Create provider directory with `benchmark.sh` and `README.md`
2. Source common functions: `source "$PROJECT_ROOT/lib/common.sh"`
3. Implement `cleanup_instances()` function for provider-specific cleanup
4. Set up trap handler: `trap generic_cleanup EXIT INT TERM`
5. Create security group/firewall rules to allow demo ports
6. Launch demo instance with docker-compose user data
7. Wait for HTTP service using `wait_for_http()` helper
8. Launch autocannon instance targeting demo IP
9. Monitor and display results

See `aws-ec2/benchmark.sh` as reference implementation.

### Kubernetes-Based Implementation (EKS-style)

When adding a Kubernetes-based provider (e.g., `gcp-gke/`, `azure-aks/`):

1. Create provider directory with `benchmark.sh` and `README.md`
2. Source common functions: `source "$PROJECT_ROOT/lib/common.sh"`
3. Implement `cleanup_instances()` function to delete all resources (cluster, node group, VPC, IAM roles, autocannon instance)
4. Set up trap handler: `trap generic_cleanup EXIT INT TERM`
5. **Create infrastructure using cloud CLI** (pure AWS CLI for EKS, no eksctl or CloudFormation):
   - Create VPC with subnets, internet gateway, and route tables
   - Create IAM roles (cluster role and node role)
   - Create managed Kubernetes cluster
   - Create managed node group
6. **Setup kubeconfig with custom context**:
   - Use `aws eks update-kubeconfig --alias <context-name>` (or equivalent)
   - Save context name as `KUBE_CONTEXT` variable
   - Use `kubectl --context "$KUBE_CONTEXT"` for all kubectl commands
7. Apply `kube.yaml` from demo directory (must include NodePort services with annotation)
8. Wait for pods to be ready
9. **Find annotated NodePort services**:
   - Search for services with `benchmark.platformatic.dev/expose: "true"`
   - Extract service names and NodePort numbers
   - Get private IP of cluster node
10. **Configure security groups**:
    - Create security group for autocannon VM
    - Add ingress rules to cluster security group for each NodePort
    - Allow autocannon to reach nodes on specific ports
11. Launch a separate VM/EC2 instance in the same VPC/subnet as cluster nodes
12. Run autocannon on the VM with SERVICE_PORTS environment variable
    - The autocannon container performs health checks before benchmarking
    - Verifies all NodePort services are accessible from within VPC
    - Only proceeds to benchmark once all services are healthy
13. Monitor VM console output and display results

**Important Design Decisions**:
- **NodePort instead of LoadBalancer**: Services use NodePort accessed via node private IPs
  - No LoadBalancer costs
  - Supports multiple services with single node IP (different ports)
  - Matches docker-compose pattern (single host, multiple ports)
  - Not exposed to internet (private VPC networking only)
- **Annotation-based discovery**: `benchmark.platformatic.dev/expose: "true"` marks services
  - User controls which services to benchmark
  - Supports multi-service demos (PM2 vs Watt)
  - User-defined NodePort numbers (consistent with docker-compose)
- **Autocannon runs on separate VM** outside cluster (same as VM-based implementations)
  - Realistic network testing from within VPC
  - No resource contention with demo application
  - Architectural consistency across all providers

See `aws-eks/benchmark.sh` as reference implementation.

## Key Environment Variables

### AWS EC2 (`aws-ec2/benchmark.sh`)
- `AWS_PROFILE` - (Required) AWS CLI profile to use
- `DEMO_NAME` - Demo to benchmark (e.g., `pm2-vs-watt`)
- `AMI_ID` - Amazon Linux 2023 AMI (default: `ami-07b2b18045edffe90`)
- `INSTANCE_TYPE` - EC2 instance type (default: `m8g.2xlarge`)
- `AUTOCANNON_IMAGE` - Autocannon Docker image (default: `platformatic/autocannon:latest`)

### AWS EKS (`aws-eks/benchmark.sh`)
- `AWS_PROFILE` - (Required) AWS CLI profile to use
- `DEMO_NAME` - (Required) Demo to benchmark (e.g., `next-watt`)
- `CLUSTER_NAME` - EKS cluster name (default: `watt-benchmark-<timestamp>`)
- `AWS_REGION` - AWS region (default: `us-east-1`)
- `NODE_TYPE` - EC2 instance type for nodes (default: `t3.xlarge`)
- `NODE_COUNT` - Number of worker nodes (default: `2`)
- `AUTOCANNON_IMAGE` - Autocannon Docker image (default: `platformatic/autocannon:latest`)
- `AMI_ID` - Amazon Linux 2023 AMI for autocannon EC2 (default: `ami-07b2b18045edffe90`)
- `AUTOCANNON_INSTANCE_TYPE` - EC2 instance type for autocannon (default: `t3.micro`)

**Note**: EKS benchmark uses pure AWS CLI (no eksctl or CloudFormation). It creates:
- VPC with subnets, internet gateway, and route tables
- IAM roles for cluster and nodes
- EKS cluster and managed node group
- Custom kubectl context (cluster name)

### pm2-vs-watt Demo
- `SCRIPT_NAME` - Which npm script to run (values: `pm2r-start`, `watt-start`, `cluster-start`)
- `WORKERS` - Number of worker processes (default: `2`)
- `PORT` - Server port (default: `3000`)
- `HOSTNAME` - Server hostname (default: `0.0.0.0`)

## Benchmark Output Interpretation

The benchmark scripts parse console output to extract autocannon results showing:
- Latency statistics (p2.5, p50, p97.5, p99, avg, stdev, max)
- Throughput (Req/Sec and Bytes/Sec)
- Total requests and data transferred

Results are automatically filtered to show only the benchmark output, excluding Docker/cloud-init noise.

## Code Style

- **Shell Scripts**: Use bash with `set -e` for error handling, follow common.sh patterns for logging (log/error/success/warning functions)
- **JavaScript Demos**: ES Modules format, Node.js 20+, minimal dependencies for accurate benchmarking
- **Docker**: Multi-stage builds not used to keep images simple, alpine base images for smaller size
