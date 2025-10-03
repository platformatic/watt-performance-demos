#!/bin/sh

PORT=3000 npm run pm2-start
PORT=3001 npm run watt-start &
PORT=3002 node server.cjs &
PORT=3003 node server.js & 
PORT=3004 node server-cluster.js
