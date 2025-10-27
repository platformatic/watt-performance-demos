# Making Next.js and Node.js Multithreaded: Watt's Performance Revolution

Most Node.js applications are single-threaded, .
While this simplicity has its benefits, it leaves significant performance on the table for modern multi-core servers. Solutions like PM2 and Node.js's built-in cluster module have helped, but they require manual configuration and come with their own complexity.

Enter **Platformatic Watt** - a runtime that makes any Node.js application, including Next.js, truly multithreaded with minimal configuration. In this post, we'll dive into comprehensive benchmarks that demonstrate Watt's performance gains and explore how it achieves this with just a simple configuration file.

## The Challenge: Unlocking Multi-Core Performance

Modern cloud instances come with multiple CPU cores, but a standard Next.js application runs on a single thread. This means that no matter how many cores your server has, your application can only utilize one of them. The typical solution involves:

1. **Node.js Cluster Module**: Manually fork worker processes and implement load balancing
2. **PM2**: Use a process manager to spawn multiple instances
3. **Horizontal Scaling**: Deploy multiple containers/pods behind a load balancer

Each approach has drawbacks - added complexity, configuration overhead, or infrastructure costs. What if you could get multi-core performance with a single configuration file?

## Benchmark Architecture

To properly evaluate Watt's performance, we built a comprehensive benchmarking framework that tests across multiple cloud providers (AWS EC2, AWS EKS) with consistent methodology:

### Three-Layer Design

**Layer 1: Common Functions**
- HTTP health checks and service readiness verification
- Logging, error handling, and cleanup automation
- Tool validation (AWS CLI, kubectl, Docker)

**Layer 2: Performance Demos**
- Self-contained applications with Docker images
- Docker Compose configurations for VM deployments (EC2)
- Kubernetes manifests for container orchestration (EKS)
- Environment-variable driven configuration for flexibility

**Layer 3: Cloud Orchestration**
- Provider-specific scripts that create infrastructure
- Automatic security group and network configuration
- Isolated load testing from separate instances
- Complete teardown after benchmarks complete

### Load Testing Methodology

All benchmarks use **Autocannon** - a fast HTTP benchmarking tool - running in a dedicated instance/container:

- **100 concurrent connections** to simulate realistic load
- **40-second warmup period** to allow JIT compilation
- **40-second test period** for measurement
- **Network isolation** - autocannon runs on separate infrastructure from the application

This ensures realistic network conditions and prevents resource contention between the application and the load tester.

## The Demos

We created two benchmarking scenarios to test different aspects of Watt's performance:

### 1. Simple HTTP Server (`pm2-vs-watt`)

A minimal HTTP server that responds with "Hello World" - perfect for measuring raw request handling performance without framework overhead.

**Three implementations:**
- **Node.js Cluster**: Native clustering with manual worker management
- **PM2 Runtime**: Industry-standard process manager in cluster mode
- **Watt Runtime**: Platformatic's multithreading solution

### 2. Next.js Application (`next-watt`)

A real-world Next.js 15.5.5 application using App Router and Tailwind CSS - demonstrating Watt's ability to make modern frameworks multithreaded.

**Three configurations:**
- **Standard Next.js**: Single-threaded Node.js process
- **PM2 + Next.js**: PM2 managing multiple Next.js instances
- **Watt + Next.js**: Watt runtime with Next.js via `@platformatic/next`

## How Watt Makes Next.js Multithreaded

The magic happens through Watt's declarative configuration system. Here's the complete `watt.json` file used in our Next.js benchmark:

```json
{
  "$schema": "https://schemas.platformatic.dev/@platformatic/next/3.0.6.json",
  "runtime": {
    "logger": {
      "level": "{PLT_SERVER_LOGGER_LEVEL}"
    },
    "verticalScaler": {
      "enabled": false
    },
    "server": {
      "hostname": "{HOSTNAME}",
      "port": "{PORT}"
    },
    "managementApi": "{PLT_MANAGEMENT_API}",
    "workers": "{WORKERS}"
  }
}
```

That's it. No code changes to your Next.js application. No manual worker management. Just a configuration file.

### What Watt Does Behind the Scenes

1. **Worker Process Management**: Spawns the specified number of worker processes, each running a complete instance of your Next.js application

2. **Automatic Load Balancing**: Distributes incoming requests across workers intelligently, ensuring even CPU utilization

3. **Health Monitoring**: Tracks worker health and can restart failed processes automatically

4. **Unified Logging**: Aggregates logs from all workers into a single stream

5. **Management API**: Provides runtime introspection and control (optional)

6. **Zero Application Changes**: Your existing Next.js code works without modification - Watt handles the multithreading layer

### Starting Your Multithreaded Next.js App

Instead of the standard `next start` command, you use:

```bash
watt start
```

The `@platformatic/next` and `wattpm` packages provide the runtime orchestration. Your package.json only needs:

```json
{
  "dependencies": {
    "@platformatic/next": "latest",
    "@platformatic/runtime": "latest",
    "wattpm": "latest",
    "next": "15.5.5"
  },
  "scripts": {
    "start:watt": "wattpm start"
  }
}
```

## The Results: Watt's Performance Gains

### Next.js Performance on Kubernetes (2-3 CPU pods)

Our most dramatic results came from the Next.js benchmarks running on AWS EKS:

#### Standard Next.js (Single-threaded)
```
Latency (avg):     29.62 ms
Throughput:        3,321.2 Req/Sec
Total Requests:    133,000 in 40.03s
```

#### Watt + Next.js (3 Workers)
```
Latency (avg):     19.54 ms  (34% faster)
Throughput:        5,298.25 Req/Sec  (59% improvement)
Total Requests:    212,000 in 40.03s
```

**Key Takeaway:** Watt delivered **59% more throughput** with **34% lower latency** by utilizing multiple CPU cores. This isn't just faster - it's nearly 80,000 more requests handled in the same time period.

### Simple HTTP Server Performance (2-3 CPU pods)

To validate Watt's performance characteristics without framework overhead, we tested a minimal HTTP server:

#### Node.js Cluster (Baseline)
```
Latency (avg):     3.26 ms
Throughput:        26,813.2 Req/Sec
Total Requests:    1,073,000
Std Dev:           2,844.52
```

#### PM2 Runtime (2 Workers)
```
Latency (avg):     3.46 ms
Throughput:        25,269.7 Req/Sec
Total Requests:    1,011,000
```

#### Watt (2 Workers)
```
Latency (avg):     2.93 ms  (10% faster than Node.js)
Throughput:        30,234.8 Req/Sec  (13% faster than Node.js)
Total Requests:    1,209,000
Std Dev:           1,469.58  (48% lower than Node.js)
```

**Key Insight:** Watt not only outperformed both native Node.js clustering and PM2, but showed **significantly better consistency** with nearly half the standard deviation. This suggests superior load balancing across workers.

## Why Watt Excels at Multithreading

### 1. Declarative Configuration
Unlike PM2 or cluster module approaches, Watt uses a single JSON configuration file. No ecosystem files, no programmatic worker management - just declare your desired state.

### 2. Framework-Agnostic
Watt works with Next.js, Express, Fastify, and custom Node.js applications. The same runtime handles all frameworks.

### 3. Production-Ready Features
- **Vertical Scaler**: Auto-adjust worker count based on load (disabled in benchmarks for consistency)
- **Management API**: Runtime introspection and control
- **Graceful Restarts**: Update code without dropping connections
- **Health Monitoring**: Automatic worker recovery

### 4. Developer Experience
Your application code remains unchanged. No conditional logic for clustering, no worker communication code - just pure application logic.

### 5. Deployment Consistency
The same `watt.json` works across:
- Local development with Docker Compose
- VM deployments on EC2
- Kubernetes deployments on EKS, GKE, or AKS

## Real-World Implications

### Cost Savings
Get 59% more throughput from the same infrastructure. This translates directly to:
- Fewer servers needed for the same traffic
- Lower cloud bills
- Reduced carbon footprint

### Better User Experience
34% lower latency means faster page loads and better Core Web Vitals scores.

### Simplified Operations
One configuration file replaces complex PM2 ecosystem configs or manual clustering code.

### Cloud Native Ready
Watt works seamlessly in both VM-based deployments (Docker Compose) and container orchestration platforms (Kubernetes), making it ideal for modern cloud architectures.

## Deployment Options

### Docker Compose (Development/EC2)

```yaml
services:
  next-node:
    build: .
    environment:
      - SCRIPT_NAME=start:node
    ports:
      - "30000:3000"

  next-watt:
    build: .
    environment:
      - SCRIPT_NAME=start:watt
      - WORKERS=2
    ports:
      - "30002:3000"
```

### Kubernetes (EKS/GKE/AKS)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: next-watt
spec:
  replicas: 1
  template:
    spec:
      containers:
      - name: next-watt
        image: platformatic/next-watt:latest
        env:
        - name: SCRIPT_NAME
          value: "start:watt"
        - name: WORKERS
          value: "3"
        resources:
          requests:
            cpu: "2"
            memory: "4Gi"
---
apiVersion: v1
kind: Service
metadata:
  name: next-watt
  annotations:
    benchmark.platformatic.dev/expose: "true"
spec:
  type: NodePort
  ports:
  - port: 3000
    nodePort: 30002
```

## Running the Benchmarks Yourself

The complete benchmark framework is open source and available at:
**github.com/platformatic/watt-performance-demos**

### Quick Start

```bash
# Clone the repository
git clone https://github.com/platformatic/watt-performance-demos
cd watt-performance-demos

# Run locally with Docker Compose
cd demos/next-watt
docker compose up

# Run benchmarks against each service
npm run bench  # Benchmarks all three configurations
```

### AWS EC2 Benchmarks

```bash
cd aws-ec2
AWS_PROFILE=your-profile DEMO_NAME=next-watt ./benchmark.sh
```

The script automatically:
1. Creates EC2 instances with the demo services
2. Launches a separate autocannon instance for load testing
3. Runs the benchmark and collects results
4. Cleans up all resources

### AWS EKS Benchmarks

```bash
cd aws-eks
AWS_PROFILE=your-profile DEMO_NAME=next-watt ./benchmark.sh
```

The script creates a complete EKS cluster using pure AWS CLI (no eksctl or CloudFormation):
1. Creates VPC, subnets, and networking
2. Sets up IAM roles for cluster and nodes
3. Creates EKS cluster and managed node group
4. Deploys the demo via Kubernetes manifests
5. Launches autocannon on a separate EC2 instance
6. Runs benchmarks and displays results
7. Tears down all infrastructure

## Conclusion

Platformatic Watt represents a paradigm shift in how we think about Node.js performance. By making multithreading **declarative** rather than **imperative**, it removes the complexity that has historically kept many applications single-threaded.

The benchmark results speak for themselves:
- **59% more throughput** for Next.js applications
- **34% lower latency** with better consistency
- **13% improvement** over native Node.js clustering for simple servers
- **Zero code changes** required to your application

Whether you're running a Next.js application serving thousands of users or a high-throughput API handling millions of requests, Watt can help you unlock the full potential of your infrastructure.

## Get Started with Watt

Ready to make your Next.js application multithreaded?

1. **Install Watt packages:**
   ```bash
   npm install @platformatic/next @platformatic/runtime wattpm
   ```

2. **Create a `watt.json` configuration:**
   ```json
   {
     "$schema": "https://schemas.platformatic.dev/@platformatic/next/3.0.6.json",
     "runtime": {
       "workers": 4
     }
   }
   ```

3. **Start your application:**
   ```bash
   wattpm start
   ```

That's it. Your Next.js application is now utilizing all available CPU cores.

## Learn More

- **Documentation**: [docs.platformatic.dev](https://docs.platformatic.dev)
- **GitHub**: [github.com/platformatic/watt](https://github.com/platformatic/watt)
- **Benchmarks**: [github.com/platformatic/watt-performance-demos](https://github.com/platformatic/watt-performance-demos)
- **Community**: Join our [Discord](https://discord.gg/platformatic)

---

*All benchmarks were conducted on AWS infrastructure using consistent instance types, network configurations, and load testing methodology. Full benchmark scripts and reproduction instructions are available in the GitHub repository.*
