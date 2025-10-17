#!/bin/sh

# Run the demo-specific benchmark script
exec /entrypoints/$DEMO_NAME.sh "$TARGET_URL"
