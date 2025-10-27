#!/bin/bash

echo "== Next.js - Node =="
npx autocannon --overallRate 10000 --connections 100 --duration 40 --warmup '[-c 100 -d 10]' "$TARGET_URL:30000"

echo "== Next.js - PM2 =="
npx autocannon --overallRate 10000 --connections 100 --duration 40 --warmup '[-c 100 -d 10]' "$TARGET_URL:30001"

echo "== Next.js - watt-extra =="
npx autocannon --overallRate 10000 --connections 100 --duration 40 --warmup '[-c 100 -d 10]' "$TARGET_URL:30002"

