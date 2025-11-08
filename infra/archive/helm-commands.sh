#!/bin/bash
# Helm commands for OpenTelemetry Demo

# Pull and extract the Helm chart for inspection
helm pull open-telemetry/opentelemetry-demo --untar

# Dry-run install to preview generated Kubernetes manifests
helm install otel-demo open-telemetry/opentelemetry-demo \
  -n otel-demo \
  --values otel-demo-values.yaml \
  --create-namespace \
  --dry-run > alt.txt

# Actual install command (when ready)
# helm install otel-demo open-telemetry/opentelemetry-demo \
#   -n otel-demo \
#   --values otel-demo-values.yaml \
#   --create-namespace

# Upgrade command
# helm upgrade otel-demo open-telemetry/opentelemetry-demo \
#   -n otel-demo \
#   --values otel-demo-values.yaml

