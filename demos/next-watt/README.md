# Next.js with Watt

We built Watt to be the best place to run any Node.js service (including Next) in any container.

To see how Watt can help improve the performance of your service, use this repo 
to run your app using multiple workers with Watt.

> ![Hint]:
> Try giving your pods some more CPUs to work with and see what that does.
> You can find some example pod sizes and benchmarks from previous runs we've done on EKS here.

This demo compares running Next.js in `watt`, `pm2`, and `node`.

## Usage

The _docker-compose.yml_ and _kube.yaml_ files are adjustable and passed into
our benchmarking scripts. Try changing the resources and `WORKERS` in these
files before running them.

Typically, `WORKERS` should match the number of CPU being used. In Kubernetes,
it can be pushed up to the limit. So, if the request is 2CPU with a limit of
3CPU then `WORKERS` can be set to `3`.

Once the demo is deployed, execute _autocannon.sh_ against the environment:

```sh
TARGET_URL=http://<ip-or-host> ./autocannon.sh
```

All deployment options use fixed port numbers so that _autocannon.sh_ can be
easily applied against any environment.

### Cloud benchmarking

The Platformatic team has created guides for using various cloud providers with
our benchmarking script. These will launch a demo into the cloud and then remove
all of the resources when completed or cancelled.

Benchmarking scripts available:

* [AWS EC2](../../aws-ec2/README.md)
* [AWS EKS](../../aws-eks/README.md)

This demo is called `next-watt`.

### Manual setup - Kubernetes

If you have a Kubernetes cluster available for testing, the _kube.yaml_ file can
be applied.

```sh
kubectl apply -f kube.yaml
```

This will deploy `Service`s of a type of `NodePort` for access. All of the
deployed `Service`s can be found with:

```sh
kubectl get service \
  -o jsonpath='{.items[?(@.metadata.annotations.benchmark.platformatic.dev/expose=="true")].metadata.name}'
```

### Manual setup - Docker Compose

This demo can be run locally using `docker compose` but be aware that
`autocannon` will be in contention for resources with the demo.

```sh
docker compose up
```

## Performance results

Performance results from our test runs are available in
[PERFORMANCE.md](./PERFORMANCE.md).
