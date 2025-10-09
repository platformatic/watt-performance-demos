#!/bin/sh

PORT=3000 npm run pm2-start
PORT=3001 npm run watt-start &
PORT=3002 node server-cluster.js
