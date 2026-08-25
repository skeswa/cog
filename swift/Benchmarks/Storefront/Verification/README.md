# Storefront verification

This is a separate, test-only SwiftPM package. It is the one correctness
boundary allowed to resolve all four Storefront runtime products.

`StorefrontAgreementTests` drives the Cog, raw Observation, memoized
Observation, and swift-state-graph implementations through the identical
eleven-phase trace. It requires each implementation to agree with the neutral
shadow model and with the other implementations on visible products, rendered
checksum, settled suggestions, order total, and request quiescence.

The same target owns `StorefrontBuildShapeTests`, which checks that the
workload and runtime manifests keep the same isolation and language settings.
Keeping this assertion here lets the dependency-free workload package remain
truly neutral.

The runtime packages do not depend on this package or on one another. The
benchmark runner separately consumes their products for measurement; it does
not host correctness tests.

Run the guarded suite from the repository root:

```sh
mise run test:storefront-agreement
```

Run `mise run test:storefront-all` before recording any cross-runtime number.
