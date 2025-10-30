# PostgreSQL Data Seeding Scripts

SQL scripts to populate the OpenTelemetry Demo PostgreSQL database with test data.

## Scripts

- **seed-simple.sql** - Basic seed data with minimal records
- **complete-seed.sql** - Complete dataset with full test data
- **seed-150k.sql** - Large dataset with 150,000 records

## Usage

```bash
# Get PostgreSQL pod name
POD=$(kubectl get pods -n otel-demo -l app.kubernetes.io/component=postgresql -o jsonpath='{.items[0].metadata.name}')

# Run seed script
kubectl cp postgres-seed/seed-simple.sql otel-demo/$POD:/tmp/seed.sql
kubectl exec -n otel-demo $POD -- psql -U root -d otel -f /tmp/seed.sql
```

## Which Seed to Use

- **seed-simple.sql** - Quick testing, minimal data
- **complete-seed.sql** - Standard testing, balanced dataset
- **seed-150k.sql** - Load testing, performance testing

## Note

Seeding is typically done during initial setup. The OpenTelemetry Demo includes its own data generation, so these scripts are optional for supplementing or resetting test data.
