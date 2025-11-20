# Infrastructure Setup

Custom Kubernetes deployment configurations for the OpenTelemetry Demo with Honeycomb integration.

## Quick Install

```bash
cd infra
./install-with-persistence.sh otel-demo-values-aws.yaml
```

This sets up:
- OpenTelemetry Demo on Kubernetes
- PostgreSQL with persistent storage (2GB PVC)
- OTel Collector sidecar for PostgreSQL metrics
- Honeycomb integration (requires HONEYCOMB_API_KEY in values file)

## Configuration Files

| File | Purpose |
|------|---------|
| `otel-demo-values.yaml` | Main Helm values (local Kubernetes) |
| `otel-demo-values-aws.yaml` | AWS-specific Helm values |
| `install-with-persistence.sh` | One-command installer script |
| `postgres-persistent-setup.yaml` | PVC + ConfigMap for PostgreSQL |
| `postgres-otel-sidecar-patch.yaml` | Adds OTel Collector sidecar |

## Detailed Guides

- [INSTALL-FROM-SCRATCH.md](INSTALL-FROM-SCRATCH.md) - Step-by-step installation
- [POSTGRESQL-LOGGING.md](POSTGRESQL-LOGGING.md) - Enable table lock logging
- [postgres-chaos/](postgres-chaos/) - Database chaos testing

## Port Forwarding

```bash
# Frontend
kubectl -n otel-demo port-forward svc/frontend-proxy 8080:8080

# Jaeger UI
kubectl -n otel-demo port-forward svc/jaeger-query 16686:16686

# Load Generator
kubectl -n otel-demo port-forward svc/load-generator 8089:8089
```

## Upstream Documentation

For general OpenTelemetry Demo documentation: https://opentelemetry.io/docs/demo/
