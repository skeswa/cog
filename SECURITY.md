# Security policy

## Supported versions

Cog is below 1.0. Security fixes go into the latest minor release. Older minor
versions are not supported unless their release notes say otherwise. Use the
latest patch for your chosen minor. Read the changelog before moving to a newer
minor because it may contain breaking changes.

## Reporting a vulnerability

Do not report a possible security flaw in a public issue. Send a
[private vulnerability report](https://github.com/skeswa/cog/security/advisories/new)
with the affected version, impact, steps to reproduce it, and any known fix. If
private reports do not work, open a public issue that asks how to contact the
maintainer privately. Do not include details about the flaw.

The public `Cog` package has no third-party dependencies. Separate benchmark
and lint tools have pinned dependencies, but normal Cog apps do not receive
them. [CI operations](./docs/maintainers/ci.md) explains runner security and
workflow permissions. `mise run workflows:check` checks those rules.
