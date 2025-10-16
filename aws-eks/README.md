# AWS EKS Benchmarking

Run Platformatic Watt performance benchmarks in Amazon EKS (Elastic Kubernetes Service).

## Overview

The `benchmark.sh` script automates the complete EKS benchmarking workflow:
1. **Create EKS cluster** - Launches a managed Kubernetes cluster with specified node configuration
2. **Apply manifests** - Deploys the demo application from `kube.yaml` in the demo directory
3. **Expose service** - Waits for LoadBalancer to provision and service to become accessible
4. **Launch autocannon** - Starts a separate EC2 instance in the same VPC to run load tests
5. **Run benchmark** - Executes autocannon from EC2 against the Kubernetes service
6. **Display results** - Shows benchmark output from the autocannon instance console
7. **Cleanup** - Automatically deletes the EKS cluster, EC2 instance, and all resources

This architecture provides realistic external load testing by running autocannon outside the cluster, similar to production traffic patterns.

## Prerequisites

- **AWS CLI v2** - Installed and configured with appropriate credentials
- **eksctl** - EKS cluster management tool ([installation guide](https://eksctl.io/installation/))
- **kubectl** - Kubernetes CLI tool ([installation guide](https://kubernetes.io/docs/tasks/tools/))
- **curl** - Used to confirm service readiness

## Usage

Run the benchmark:

```sh
AWS_PROFILE=<profile-to-load> DEMO_NAME=<demo-name> ./benchmark.sh
```

Example:
```sh
AWS_PROFILE=myprofile DEMO_NAME=k8s-next-watt ./benchmark.sh
```

You can also pass the demo name as the first argument:
```sh
AWS_PROFILE=myprofile ./benchmark.sh k8s-next-watt
```

## Configuration

Optional environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `AWS_PROFILE` | - | **(Required)** AWS CLI profile to use |
| `DEMO_NAME` | - | **(Required)** Name of demo directory containing kube.yaml |
| `CLUSTER_NAME` | `watt-benchmark-<timestamp>` | EKS cluster name |
| `AWS_REGION` | `us-east-1` | AWS region for EKS cluster |
| `NODE_TYPE` | `t3.xlarge` | EC2 instance type for worker nodes |
| `NODE_COUNT` | `2` | Number of worker nodes |
| `AUTOCANNON_IMAGE` | `platformatic/autocannon:latest` | Docker image for load testing |
| `AMI_ID` | `ami-07b2b18045edffe90` | Amazon Linux 2023 AMI for autocannon |
| `AUTOCANNON_INSTANCE_TYPE` | `t3.micro` | EC2 instance type for autocannon |

## How it Works

1. **Validation** - Checks for required tools (AWS CLI, eksctl, kubectl) and validates that `kube.yaml` exists in the demo directory

2. **Cluster Creation** - Creates an EKS cluster with managed node groups
   - Takes approximately 15-20 minutes
   - Uses OIDC provider for IAM integration
   - Automatically configures kubectl context

3. **Node Readiness** - Waits for all worker nodes to reach Ready state

4. **Deploy Demo** - Applies Kubernetes manifests from `demos/<demo-name>/kube.yaml`

5. **Pod Readiness** - Waits for all pods to reach Running state

6. **Discover Services** - Finds all NodePort services with annotation `benchmark.platformatic.dev/expose: "true"`
   - Extracts service names and NodePort numbers
   - Gets private IP of a cluster node

7. **Configure Security** - Sets up network access for benchmarking
   - Creates security group for autocannon EC2 instance
   - Adds ingress rules to cluster security group for each NodePort
   - Allows autocannon to reach services via NodePort

8. **Launch Autocannon** - Starts an EC2 instance in same VPC/subnet as EKS nodes
   - Instance pulls the autocannon Docker image
   - Runs load tests against node private IP + NodePorts
   - Provides realistic network testing from within VPC

9. **Monitor Results** - Polls the EC2 instance console output and displays benchmark results

10. **Cleanup** - Deletes the autocannon instance, EKS cluster, and security groups (triggered automatically on exit)

## Demo Kubernetes Manifest Requirements

Each demo must provide a `kube.yaml` file containing:

1. **Deployment(s)** - Application workload definition with container(s)
   - Must expose ports matching the NodePort service ports
   - Should include appropriate resource requests/limits

2. **NodePort Service(s)** - Services to be benchmarked must:
   - Have `type: NodePort`
   - Include annotation `benchmark.platformatic.dev/expose: "true"`
   - Specify explicit `nodePort` values (user-controlled port numbers)
   - Port numbers should match those used in docker-compose.yml

**The annotation marks services for benchmarking**. The script will:
- Find all services with `benchmark.platformatic.dev/expose: "true"`
- Configure security groups to allow access to specified NodePorts
- Use node private IP + NodePort for benchmarking
- Keep demos cloud-agnostic (NodePort works on any Kubernetes)

Example structure with NodePort services:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: my-demo
  template:
    metadata:
      labels:
        app: my-demo
    spec:
      containers:
      - name: app
        image: my-image:latest
        ports:
        - containerPort: 3000
        resources:
          requests:
            cpu: 500m
            memory: 512Mi
          limits:
            cpu: 1000m
            memory: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: my-demo-service
  annotations:
    benchmark.platformatic.dev/expose: "true"  # Required for benchmarking
spec:
  type: NodePort
  ports:
  - port: 3000
    targetPort: 3000
    nodePort: 30000  # User-defined, consistent with docker-compose
  selector:
    app: my-demo
```

For multiple services (e.g., comparing PM2 vs Watt):
```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: pm2-service
  annotations:
    benchmark.platformatic.dev/expose: "true"
spec:
  type: NodePort
  ports:
  - port: 3000
    targetPort: 3000
    nodePort: 30000
  selector:
    app: pm2
---
apiVersion: v1
kind: Service
metadata:
  name: watt-service
  annotations:
    benchmark.platformatic.dev/expose: "true"
spec:
  type: NodePort
  ports:
  - port: 3000
    targetPort: 3000
    nodePort: 30001
  selector:
    app: watt
```

## Cost Considerations

**WARNING**: Running this script will incur AWS costs:
- EKS cluster control plane: ~$0.10/hour
- EC2 worker nodes: Varies by instance type (t3.xlarge ~$0.17/hour × node count)
- Autocannon EC2 instance: t3.micro ~$0.01/hour (minimal, only runs during benchmark)
- Data transfer: Between autocannon EC2 and nodes (within same VPC, minimal cost)

**Benefits of NodePort approach**:
- No LoadBalancer costs (saves ~$0.025/hour per service)
- Simpler networking for multi-service demos
- Faster provisioning (no wait for LoadBalancer to provision)

The script automatically cleans up resources on exit, but ensure cleanup completes to avoid unexpected charges.

## Troubleshooting

### Cluster creation fails
- Verify AWS credentials and permissions (requires EKS, EC2, VPC, IAM permissions)
- Check if you've hit AWS service limits (EC2 instances, VPCs, etc.)

### Pods not starting
- Check pod status: `kubectl get pods --all-namespaces`
- View pod logs: `kubectl logs <pod-name>`
- Describe pod for events: `kubectl describe pod <pod-name>`

### LoadBalancer not getting external address
- Verify AWS Load Balancer Controller is configured (eksctl sets this up automatically)
- Check service events: `kubectl describe service <service-name>`
- Ensure security groups allow traffic

### Manual cleanup
If the script exits unexpectedly and doesn't clean up:
```sh
eksctl delete cluster --name <cluster-name> --region us-east-1 --profile <profile>
```

## Security Notes

- The cluster is created with managed node groups and OIDC provider
- Services use NodePort (not exposed to internet, only accessible within VPC)
- Autocannon EC2 instance is placed in same VPC/subnet as EKS nodes
- Security groups configured with minimal access:
  - Autocannon can reach specific NodePorts on cluster nodes
  - NodePorts are NOT exposed to internet
- All resources (cluster, EC2 instance, security groups) are automatically deleted after benchmarking
- For production use, consider:
  - Private subnets for nodes (already recommended in this setup)
  - Network policies to restrict pod-to-pod communication
  - Pod security standards
  - More restrictive security group rules
