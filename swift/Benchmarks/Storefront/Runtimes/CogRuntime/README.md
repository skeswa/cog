# The Cog Storefront runtime

This separate SwiftPM package contains the Cog implementation of the neutral
Storefront workload. Its package name remains `cog-storefront`; the directory
is named `CogRuntime` because a local package directory named `Cog` would share
the root package's SwiftPM identity and make consumers unable to distinguish the
two dependencies.

## Targets and dependencies

| Target               | What it owns                                                                                       | Depends on                                |
| -------------------- | -------------------------------------------------------------------------------------------------- | ----------------------------------------- |
| `CogStorefront`      | 53 Cog declarations, domain operations, assembly mechanism, and `CogStorefrontRuntime` adapter     | `StorefrontWorkload`, `Cog`, `CogTesting` |
| `CogStorefrontTests` | declaration census, runtime semantics, and the complete trace against the independent shadow model | `CogStorefront`, `StorefrontWorkload`     |

The package depends only on the root Cog package and
[`Workload`](../../Workload/). It never resolves the benchmark harness,
allocator interposer, or any comparison runtime. Both the headless runner and
the SwiftUI app consume this same `CogStorefront` product.

`storefrontSwiftSettings` is copied verbatim across the workload and runtime
manifests because SwiftPM manifests cannot import one another. The build-shape
test in [`Verification`](../../Verification/) rejects any drift.

## Running the tests

```sh
mise run test:storefront-cog
```

Use the wrapper rather than a bare filtered `swift test`. It verifies that a
filter selects tests and requires a nonzero authoritative executed-test count.

`mise run test:storefront-all` runs this suite with the neutral workload, the
two Observation ports, the swift-state-graph port, and the agreement gate.
