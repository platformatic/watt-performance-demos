#!/bin/sh

# Health check function - wait for services to be available
wait_for_service() {
  local url=$1
  local max_attempts=${2:-60}
  local retry_delay=${3:-5}

  echo "Waiting for service at $url..."

  for i in $(seq 1 $max_attempts); do
    if curl -f -s -m 5 "$url" > /dev/null 2>&1; then
      echo "Service is ready at $url"
      return 0
    fi

    if [ $((i % 10)) -eq 0 ]; then
      echo "Still waiting for $url... (attempt $i/$max_attempts)"
    fi

    sleep "$retry_delay"
  done

  echo "Service not ready at $url after $((max_attempts * retry_delay)) seconds"
  return 1
}

# If SERVICE_PORTS is provided, do health checks first
if [ -n "$SERVICE_PORTS" ]; then
  echo "=== Health Checks ==="

  # Split comma-separated ports and check each
  IFS=',' read -ra PORTS <<< "$SERVICE_PORTS"
  for port in "${PORTS[@]}"; do
    if ! wait_for_service "http://$TARGET_URL:$port"; then
      echo "ERROR: Service health check failed for port $port"
      exit 1
    fi
  done

  echo "=== All services are healthy ==="
  echo ""
fi

# Run the demo-specific benchmark script
exec /entrypoints/$DEMO_NAME.sh "$TARGET_URL"
