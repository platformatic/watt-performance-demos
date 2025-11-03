# GCP Google Compute Engine (GCE) Benchmarking

Run Platformatic Watt performance benchmarks in GCE.

## Overview

The `benchmark.sh` script launches two GCE instances:
1. **Demo instance** - Runs a performance demo web service (PM2 vs Watt comparison)
2. **Autocannon instance** - Runs load testing against the demo service

The script automatically coordinates the launch sequence, waits for services to be ready, executes the benchmark, displays results, and cleans up resources.

## Prerequisites

- `gcloud` CLI installed and configured
    - See the [documentation from Google](https://cloud.google.com/sdk/docs/install) for installation
- `curl` - used to confirm that the demo instance is ready

## Usage

Run the benchmark:

```sh
GCP_PROJECT=<project-name> ./benchmark.sh
```

## Configuration

Optional environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `IMAGE_FAMILY` | `ubuntu-2204-lts` | Base OS |
| `IMAGE_PROJECT` | `ubuntu-os-cloud` | Project the OS comes from |
| `MACHINE_TYPE` | `n2-standard-8` | GCE machine type |
| `AUTOCANNON_IMAGE` | `platformatic/autocannon:latest` | Docker image for autocannon service |
| `GCP_ZONE` | `us-central1-a` | Where to deploy GCE |


## How it Works

1. Launch Demo Instance
2. Launch Autocannon Instance
3. Monitor Results
4. Cleanup

## Security Notes

- Instances are tagged
- Automatic cleanup of resources
