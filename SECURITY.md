# Security policy

## Supported versions

Cog is pre-1.0. Security fixes are made on the latest published minor release;
older minor lines are not maintained unless a release note explicitly says
otherwise. Consumers should use the latest patch within the minor they have
selected and review the changelog before taking a newer minor.

## Reporting a vulnerability

Do not disclose a suspected vulnerability in a public issue. Use the
repository's [private vulnerability report](https://github.com/skeswa/cog/security/advisories/new)
to describe the affected version, impact, reproduction, and any suggested
mitigation. If private reporting is unavailable, open a public issue asking for
a private maintainer contact without including vulnerability details.

The shipping `Cog` package resolves with no third-party dependencies. Separate
benchmark and lint-development packages do have pinned dependencies, but they
are not part of an ordinary consumer's resolved graph. The CI trust boundary,
self-hosted runner controls, and workflow permission contract are documented in
`docs/maintainers/ci.md` and checked by `mise run workflows:check`.
