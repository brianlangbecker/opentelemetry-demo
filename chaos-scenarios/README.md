# Chaos Engineering Scenarios

This directory contains ready-to-use chaos engineering and failure scenario guides for the OpenTelemetry Demo.

---

## 📚 **Available Scenarios**

### **Memory & Resource Exhaustion**

| **Scenario**                | **File**                                                           | **Target Service**                | **Time to Failure**            |
| --------------------------- | ------------------------------------------------------------------ | --------------------------------- | ------------------------------ |
| Memory Spike / Sudden Crash | [memory-tracking-spike-crash.md](memory-tracking-spike-crash.md)   | Checkout (Go) + Accounting (.NET) | Configurable: slow/medium/fast |
| Gradual Memory Leak         | [memory-leak-gradual-checkout.md](memory-leak-gradual-checkout.md) | Checkout (Go)                     | 10-20 minutes                  |
| JVM GC Thrashing            | [jvm-gc-thrashing-ad-service.md](jvm-gc-thrashing-ad-service.md)   | Ad Service (Java)                 | Continuous (10s cycles)        |

### **Disk & Storage Pressure**

| **Scenario**                  | **File**                                                               | **Target** | **Time to Failure** |
| ----------------------------- | ---------------------------------------------------------------------- | ---------- | ------------------- |
| Filesystem Growth / Disk Full | [filesystem-growth-crash-simple.md](filesystem-growth-crash-simple.md) | OpenSearch | 2-3 hours           |
| PostgreSQL IOPS Pressure      | [postgres-disk-iops-pressure.md](postgres-disk-iops-pressure.md)       | PostgreSQL | 2-4 hours           |
| PostgreSQL Cache Chaos Demo   | [postgres-chaos-iops-demo.md](postgres-chaos-iops-demo.md)             | PostgreSQL | Immediate           |

**Setup Guide:**

- [postgres-seed-for-iops.md](postgres-seed-for-iops.md) - Pre-seed database for instant IOPS pressure (optional)

### **Infrastructure Failures**

| **Scenario**           | **File**                                                   | **Method**             | **Time to Failure** |
| ---------------------- | ---------------------------------------------------------- | ---------------------- | ------------------- |
| DNS Resolution Failure | [dns-resolution-failure.md](dns-resolution-failure.md)     | Scale CoreDNS to 0     | Immediate to 5 min  |
| DNS Capacity Issues    | [dns-insufficient-coredns.md](dns-insufficient-coredns.md) | Scale CoreDNS down 80% | 3-10 minutes        |

---

## 🚀 **Quick Start**

1. **Choose a scenario** from the list above
2. **Read the guide** - each file is a complete standalone guide
3. **Follow the steps** - all scenarios are ready to use, no code changes needed
4. **Monitor in Honeycomb** - queries provided in each guide

---

## 📖 **Main Documentation**

For a comprehensive overview, matrix view, and category breakdowns, see:

- **[ChaosTesting.md](../ChaosTesting.md)** - Master index of all chaos scenarios

For general verification:

- **[verify-postgres.md](../infra/verify-postgres.md)** - PostgreSQL verification and troubleshooting

---

## ✅ **Scenario Template**

Each scenario guide includes:

- **Overview** - What it demonstrates
- **Prerequisites** - Required setup
- **How It Works** - Technical explanation
- **Step-by-Step Instructions** - Clear execution steps
- **Honeycomb Queries** - 10+ ready-to-use queries
- **Expected Timeline** - What to expect and when
- **Troubleshooting** - Common issues and fixes
- **Cleanup** - How to reset

---

## 🎯 **Use Cases**

These scenarios are perfect for:

- **Training** - Teaching observability and incident response
- **Demos** - Showing monitoring capabilities
- **Testing** - Validating alerting and dashboards
- **SRE Practice** - Chaos engineering exercises
- **Customer Presentations** - Real-world failure scenarios

---

## 🔗 **Related Resources**

- [OpenTelemetry Demo](https://github.com/open-telemetry/opentelemetry-demo)
- [Chaos Engineering Principles](https://principlesofchaos.org/)
- [Honeycomb Documentation](https://docs.honeycomb.io)
