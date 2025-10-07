# AWS EC2 Benchmarking

Run Platformatic Watt performance benchmarks in EC2.

## Overview

The `benchmark.sh` script launches two EC2 instances:
1. **Demo instance** - Runs a performance demo web service (PM2 vs Watt comparison)
2. **Autocannon instance** - Runs load testing against the demo service

The script automatically coordinates the launch sequence, waits for services to be ready, executes the benchmark, displays results, and cleans up resources.

## Prerequisites

- AWS CLI v2 installed and configured
- `curl` - used to confirm that the demo instance is ready

## Usage

Run the benchmark:

```sh
AWS_PROFILE=<profile-to-load> ./benchmark.sh
```

## Configuration

Optional environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `AMI_ID` | `ami-0c02fb55956c7d316` | Amazon Linux 2023 AMI |
| `INSTANCE_TYPE` | `t3.micro` | EC2 instance type |
| `DEMO_IMAGE` | `platformatic/pm2-vs-watt:latest` | Docker image for demo service |
| `DEMO_PORTS` | `3000-3004` | Port for demo service |
| `AUTOCANNON_IMAGE` | `platformatic/autocannon:latest` | Docker image for autocannon service |


## How it Works

1. Launch Demo Instance
2. Launch Autocannon Instance
3. Monitor Results
4. Cleanup

## Security Notes

- Instances are tagged
- Automatic cleanup
