#!/bin/sh

TARGET_URL="$1"

if [ -z "$TARGET_URL" ]; then
  echo "Error: target_url is required"
  echo "Usage: $0 <target_url>"
  exit 1
fi

autocannon --connections 100 --duration 40 --warmup '[-c 100 -d 10]' "$TARGET_URL:3000"
echo ""
autocannon --connections 100 --duration 40 --warmup '[-c 100 -d 10]' "$TARGET_URL:3001"
echo ""
autocannon --connections 100 --duration 40 --warmup '[-c 100 -d 10]' "$TARGET_URL:3002"
echo ""
autocannon --connections 100 --duration 40 --warmup '[-c 100 -d 10]' "$TARGET_URL:3003"
echo ""
autocannon --connections 100 --duration 40 --warmup '[-c 100 -d 10]' "$TARGET_URL:3004"
