# HTTP Server

We built Watt to be the best place to run any Node.js service (including Next) in any container.

To see how Watt can help improve the performance of your service, use this repo
to run your app using multiple workers with Watt.

> [!Tip]
> Try giving your pods some more CPUs to work with and see what that does.
> You can find some example pod sizes and benchmarks from previous runs we've done on EKS here.

This demo compares running an HTTP Server in `watt`, `pm2`, and `node:cluster`.

## Usage

The _docker-compose.yml_ and _kube.yaml_ files are adjustable and passed into
our benchmarking scripts. Try changing the resources and `WORKERS` in these
files before running them.

Typically, `WORKERS` should match the number of CPU being used. In Kubernetes,
it can be pushed up to the limit. So, if the request is 2CPU with a limit of
3CPU then `WORKERS` can be set to `3`.

### Cloud benchmarking

The Platformatic team has created guides for using various cloud providers with
our benchmarking script. These will launch a demo into the cloud and then remove
all of the resources when completed or cancelled.

Benchmarking scripts available:

* [AWS EC2](../../aws-ec2/README.md)
* [AWS EKS](../../aws-eks/README.md)

This demo is called `pm2-vs-watt`.

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

Once the demo is deployed, execute _autocannon.sh_ against the environment:

```sh
TARGET_URL=http://<ip-or-host> ./autocannon.sh
```

All deployment options use fixed port numbers so that _autocannon.sh_ can be
easily applied against any environment.

### Manual setup - Docker Compose

This demo can be run locally using `docker compose` but be aware that
`autocannon` will be in contention for resources with the demo.

```sh
docker compose up
```

Once the demo is deployed, execute _autocannon.sh_ against the environment:

```sh
TARGET_URL=http://<ip-or-host> ./autocannon.sh
```

All deployment options use fixed port numbers so that _autocannon.sh_ can be
easily applied against any environment.

## Performance results

The complete results of our tests runs are available in [PERFORMANCE.md](./PERFORMANCE.md).

This is a comparison in Kubernetes with each deployment running 2-3 CPUs and
each having a HPA with min 2 and max 10, averaging 50% CPU utilization.

Node.js Cluster:
```sh
Running 40s warmup @ http://10.0.1.192:30002
 100 -d 10 connections
Running 40s test @ http://10.0.1.192:30002
100 connections
┌─────────┬──────┬──────┬───────┬──────┬─────────┬────────┬───────┐
│ Stat    │ 2.5% │ 50%  │ 97.5% │ 99%  │ Avg     │ Stdev  │ Max   │
├─────────┼──────┼──────┼───────┼──────┼─────────┼────────┼───────┤
│ Latency │ 2 ms │ 3 ms │ 6 ms  │ 7 ms │ 3.26 ms │ 1.6 ms │ 79 ms │
└─────────┴──────┴──────┴───────┴──────┴─────────┴────────┴───────┘
┌───────────┬─────────┬─────────┬─────────┬─────────┬──────────┬──────────┬─────────┐
│ Stat      │ 1%      │ 2.5%    │ 50%     │ 97.5%   │ Avg      │ Stdev    │ Min     │
├───────────┼─────────┼─────────┼─────────┼─────────┼──────────┼──────────┼─────────┤
│ Req/Sec   │ 19,519  │ 19,519  │ 26,015  │ 30,783  │ 26,813.2 │ 2,844.52 │ 19,513  │
├───────────┼─────────┼─────────┼─────────┼─────────┼──────────┼──────────┼─────────┤
│ Bytes/Sec │ 3.49 MB │ 3.49 MB │ 4.66 MB │ 5.51 MB │ 4.8 MB   │ 509 kB   │ 3.49 MB │
└───────────┴─────────┴─────────┴─────────┴─────────┴──────────┴──────────┴─────────┘
Req/Bytes counts sampled once per second.
# of samples: 40
1073k requests in 40.08s, 192 MB read
```

pm2-runtime with 2 workers:
```sh
Running 40s warmup @ http://10.0.1.192:30000
 100 -d 10 connections
Running 40s test @ http://10.0.1.192:30000
100 connections
┌─────────┬──────┬──────┬───────┬──────┬─────────┬─────────┬───────┐
│ Stat    │ 2.5% │ 50%  │ 97.5% │ 99%  │ Avg     │ Stdev   │ Max   │
├─────────┼──────┼──────┼───────┼──────┼─────────┼─────────┼───────┤
│ Latency │ 2 ms │ 3 ms │ 7 ms  │ 8 ms │ 3.46 ms │ 1.68 ms │ 70 ms │
└─────────┴──────┴──────┴───────┴──────┴─────────┴─────────┴───────┘
┌───────────┬─────────┬─────────┬─────────┬────────┬──────────┬──────────┬─────────┐
│ Stat      │ 1%      │ 2.5%    │ 50%     │ 97.5%  │ Avg      │ Stdev    │ Min     │
├───────────┼─────────┼─────────┼─────────┼────────┼──────────┼──────────┼─────────┤
│ Req/Sec   │ 15,439  │ 15,439  │ 26,143  │ 26,799 │ 25,269.7 │ 2,502.62 │ 15,438  │
├───────────┼─────────┼─────────┼─────────┼────────┼──────────┼──────────┼─────────┤
│ Bytes/Sec │ 2.76 MB │ 2.76 MB │ 4.68 MB │ 4.8 MB │ 4.52 MB  │ 448 kB   │ 2.76 MB │
└───────────┴─────────┴─────────┴─────────┴────────┴──────────┴──────────┴─────────┘
Req/Bytes counts sampled once per second.
# of samples: 40
1011k requests in 40.08s, 181 MB read
```

watt-extra with 2 workers:
```sh
Running 40s warmup @ http://10.0.1.192:30001
 100 -d 10 connections
Running 40s test @ http://10.0.1.192:30001
100 connections
┌─────────┬──────┬──────┬───────┬──────┬─────────┬─────────┬───────┐
│ Stat    │ 2.5% │ 50%  │ 97.5% │ 99%  │ Avg     │ Stdev   │ Max   │
├─────────┼──────┼──────┼───────┼──────┼─────────┼─────────┼───────┤
│ Latency │ 2 ms │ 2 ms │ 5 ms  │ 5 ms │ 2.93 ms │ 1.36 ms │ 87 ms │
└─────────┴──────┴──────┴───────┴──────┴─────────┴─────────┴───────┘
┌───────────┬─────────┬─────────┬─────────┬─────────┬──────────┬──────────┬─────────┐
│ Stat      │ 1%      │ 2.5%    │ 50%     │ 97.5%   │ Avg      │ Stdev    │ Min     │
├───────────┼─────────┼─────────┼─────────┼─────────┼──────────┼──────────┼─────────┤
│ Req/Sec   │ 21,423  │ 21,423  │ 30,463  │ 31,087  │ 30,234.8 │ 1,469.58 │ 21,413  │
├───────────┼─────────┼─────────┼─────────┼─────────┼──────────┼──────────┼─────────┤
│ Bytes/Sec │ 3.83 MB │ 3.83 MB │ 5.45 MB │ 5.57 MB │ 5.41 MB  │ 263 kB   │ 3.83 MB │
└───────────┴─────────┴─────────┴─────────┴─────────┴──────────┴──────────┴─────────┘
Req/Bytes counts sampled once per second.
# of samples: 40
1209k requests in 40.06s, 216 MB read
```
