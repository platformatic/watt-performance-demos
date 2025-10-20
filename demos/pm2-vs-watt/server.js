import { createServer } from 'http';
import { response } from './response.js'

const server = createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(response()));
})

const host = process.env.HOSTNAME || '127.0.0.1'
const port = process.env.PORT || 3000

server.listen({ host, port, reusePort: Boolean(process.env.REUSE_PORT) })
