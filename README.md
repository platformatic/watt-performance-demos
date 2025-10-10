# Watt Performance Demos

Multi-cloud benchmarking framework comparing PM2 vs Watt across different cloud providers.

## Architecture Overview

This repository implements a standardized benchmarking architecture designed for easy extension across multiple cloud providers:

- **Common Functions Library** (`lib/common.sh`) - Shared functionality across all locations
- **Performance Demos** (`performance-demos/`) - Collection of demos
- **Cloud Provider Locations** (`aws-ec2/`, `gcp-gce/`, etc.) - Provider-specific orchestration

How it works:

![Showing a user executing a benchmark.sh and it creating cloud-specific instances, running autocannon against demos, and then cleaning up](./watt-performance-demos.png "How this repository works")

## Cloud Providers

Demos can be run on a number of supported cloud providers instructions. Here are
instructions:

* [AWS EC2](./aws-ec2/README.md)

### Adding New Cloud Providers

To add a new cloud provider (e.g., `gcp-gce/`):

1. Create a new directory named after the provider
2. Implement the _benchmark.sh_
3. Create _README.md_ for specific usage instructions
