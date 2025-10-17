# AWS EKS Benchmarking

Run Platformatic Watt performance benchmarks in Amazon EKS (Elastic Kubernetes Service).

## Overview

The `benchmark.sh` script automates the creation of an EKS benchmarking
workflow. An EKS cluster and EC2 instance are created, with the EC2 instance
running `autocannon` against the cluster.

## Prerequisites

- **AWS CLI v2** - Installed and configured with appropriate credentials (version 2.12.3 or later)
- **kubectl** - Kubernetes CLI tool ([installation guide](https://kubernetes.io/docs/tasks/tools/))
- **jq** - JSON processor for parsing AWS CLI output

## Usage

Run the benchmark:

```sh
AWS_PROFILE=<profile-to-load> ./benchmark.sh <demo-name>
```

Example:
```sh
AWS_PROFILE=myprofile ./benchmark.sh next-watt
```

## Configuration

Optional environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `AWS_PROFILE` | - | **(Required)** AWS CLI profile to use |
| `CLUSTER_NAME` | `watt-benchmark-<timestamp>` | EKS cluster name |
| `AWS_REGION` | `us-east-1` | AWS region for EKS cluster |
| `NODE_TYPE` | `m5.2xlarge` | Instance type for EKS worker nodes |
| `NODE_COUNT` | `2` | Number of worker nodes |
| `AUTOCANNON_IMAGE` | `platformatic/autocannon:latest` | Docker image for load testing |
| `AMI_ID` | `ami-07b2b18045edffe90` | Amazon Linux 2023 AMI for autocannon |
| `AUTOCANNON_INSTANCE_TYPE` | `c7gn.large` | EC2 instance type for autocannon |

> [!Note]
> The default maximum number of vCPU that AWS supports is 32. The default settings here
> use 26 vCPU.

## How it Works

1. Create cluster and related resources
2. Install demo into cluster
3. Launch and execute autocannon against deployed services
4. Monitor for results
5. Cleanup up all created resources

## Demo Kubernetes Manifest Requirements

Each demo must provide a `kube.yaml` file containing:

1. **Deployment(s)** - Application workload definition with container(s)
   - Must expose ports matching the NodePort service ports
   - Should include appropriate resource requests/limits

2. **NodePort Service(s)** - Services to be benchmarked must:
   - Have `type: NodePort`
   - Include annotation `benchmark.platformatic.dev/expose: "true"`
   - Specify explicit `nodePort` values so they can be mapped to a SG
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

The script automatically cleans up resources on exit, but ensure cleanup completes to avoid unexpected charges.

## Troubleshooting

### Cluster creation fails
- Verify AWS credentials and permissions (requires EKS, EC2, VPC, IAM permissions)
- Check if you've hit AWS service limits (EC2 instances, VPCs, EKS clusters, etc.)
- Ensure AWS CLI version is 2.12.3 or later (`aws --version`)

### Pods not starting
- Check pod status: `kubectl get pods --all-namespaces`
- View pod logs: `kubectl logs <pod-name>`
- Describe pod for events: `kubectl describe pod <pod-name>`

### Manual cleanup
If the script exits unexpectedly and doesn't clean up, delete resources in this order:
```sh
# 1. Delete node group
aws eks delete-nodegroup --cluster-name <cluster-name> --nodegroup-name <cluster-name>-nodegroup --region us-east-1 --profile <profile>

# 2. Delete cluster
aws eks delete-cluster --name <cluster-name> --region us-east-1 --profile <profile>

# 3. Delete VPC resources (get VPC ID from AWS console or list VPCs with tag)
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=eks-vpc-<cluster-name>" --query "Vpcs[0].VpcId" --output text
# Then delete IGW, subnets, route tables, and VPC using the VPC ID

# 4. Delete IAM roles (detach policies first, then delete)
aws iam detach-role-policy --role-name eks-node-role-<cluster-name> --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy --profile <profile>
aws iam detach-role-policy --role-name eks-node-role-<cluster-name> --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly --profile <profile>
aws iam detach-role-policy --role-name eks-node-role-<cluster-name> --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy --profile <profile>
aws iam delete-role --role-name eks-node-role-<cluster-name> --profile <profile>

aws iam detach-role-policy --role-name eks-cluster-role-<cluster-name> --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy --profile <profile>
aws iam delete-role --role-name eks-cluster-role-<cluster-name> --profile <profile>
```

## Security Notes

- The cluster is created with managed node groups and OIDC provider
- Services use NodePort (not exposed to internet, only accessible within VPC)
- Autocannon EC2 instance is placed in same VPC/subnet as EKS nodes
- Security groups configured with minimal access:
  - Autocannon can reach specific NodePorts on cluster nodes
  - NodePorts are NOT exposed to internet
- All resources (cluster, EC2 instance, security groups) are automatically deleted after benchmarking
