#!/bin/sh

TARGET_URL="$1"

if [ -z "$TARGET_URL" ]; then
  echo "Error: target_url is required"
  echo "Usage: $0 <target_url>"
  exit 1
fi

echo "== Next.js - Node =="
autocannon --connections 100 --duration 40 --warmup '[-c 100 -d 10]' "$TARGET_URL:30000"

echo "== Next.js - watt-extra =="
autocannon --connections 100 --duration 40 --warmup '[-c 100 -d 10]' "$TARGET_URL:30042"

