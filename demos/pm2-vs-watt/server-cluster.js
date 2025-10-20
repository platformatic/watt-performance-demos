import cluster from 'cluster';
import { cpus } from 'os';
import { createServer } from 'http';
import { response } from './response.js'

const numWorkers = process.env.WORKERS;

if (cluster.isPrimary) {
  console.log(`Primary ${process.pid} is running`);

  // Fork workers
  for (let i = 0; i < numWorkers; i++) {
    cluster.fork();
  }

  cluster.on('exit', (worker, code, signal) => {
    console.log(`Worker ${worker.process.pid} died`);
    // Replace the dead worker
    cluster.fork();
  });
} else {
  // Workers share the TCP connection
  const server = createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(response()));
  });

  const host = process.env.HOSTNAME || '127.0.0.1'
  const port = process.env.PORT || 3000
  server.listen({ host, port });
  console.log(`Worker ${process.pid} started`);
}
