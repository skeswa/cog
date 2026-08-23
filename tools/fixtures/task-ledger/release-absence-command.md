# Fixture: release-side gate greens without their proving commands

The gate `M1-02` greens a release-absence scenario without naming
`test:compilefail` and a release-configuration scenario without naming
`test:release`, so `proof-mode-command` must fire twice — gates are exempt for
suite greens, but a release-side green names the command that shows it.

## M0 tasks

- **M0-01** _(Infrastructure)_ — Scaffold the package.
  _Verify: `mise run test`._

## M1 tasks

- **M1-01** _(Behavior)_ — Add the first behavior.
  _Depends: M0-01._
  _Verify: `mise run test --filter DECL-01`._
  _Greens: DECL-01._
- **M1-02** _(Gate)_ — Close the milestone.
  _Depends: M1-01._
  _Verify: `mise run test:matrix`._
  _Greens: DECL-02, DECL-03._
