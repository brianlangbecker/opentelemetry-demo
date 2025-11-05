#!/bin/sh
set -x  # Enable shell debugging
echo "=== WRAPPER START ===" >&2
echo "PID: $$" >&2
echo "PWD: $(pwd)" >&2
ls -la /usr/src/app/ >&2
echo "About to exec..." >&2
sleep 1  # Give Kubernetes time to capture logs
exec /usr/src/app/product-catalog "$@"

