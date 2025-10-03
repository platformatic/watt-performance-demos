const { createServer } = require('node:http')

const server = createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('Hello World\n');
})

const host = process.env.HOSTNAME || '127.0.0.1'
const port = process.env.PORT || 3000

server.listen({ host, port, reusePort: true })
