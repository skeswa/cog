# Cog benchmark workspace

This directory is a container for Cog's performance suites, not a SwiftPM
package. Package roots and applications are visible as siblings rather than
nested invisibly inside the benchmark runner:

```text
swift/Benchmarks/
  Runner/                  headless Ordo One benchmark package
    Benchmarks/
      CogCore/             Cog-specific graph and allocation cuts
      RuntimeComparison/   shared synthetic shapes across three runtimes
      Storefront/          application-shaped headless cuts
  Storefront/              shared commerce suite
    Workload/              dependency-free workload package
    Runtimes/
      CogRuntime/          Cog implementation package
      Observation/         raw and hand-memoized implementations
      StateGraph/          swift-state-graph implementation and probes
    Verification/          cross-runtime agreement package
    Apps/Cog/              SwiftUI/XCTest benchmark driver
```

The separation is functional. [`Runner`](./Runner/) owns the benchmark harness,
allocator interposer, thresholds, baselines, and measurement probes; nothing a
Cog consumer or Storefront app resolves depends on it. [`Storefront`](./Storefront/)
owns the workload and runtime implementations independently of how they are
measured.

Run the common entry points from the repository root:

```sh
mise run test:storefront-all
mise run bench
mise run test:storefront-ui
```

Read [`Runner/README.md`](./Runner/README.md) for measurement mechanics and
[`Storefront/README.md`](./Storefront/README.md) for the application-shaped
comparison design.
