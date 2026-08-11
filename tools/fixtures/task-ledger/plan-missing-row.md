# Fixture: a milestone the plan never maps

The ledger defines M0 and M1, but the paired plan's milestone map has a row
only for M0, so `plan-milestone-row` must fire for M1. An unmapped milestone is
scope the plan never claims.

## M0 tasks

- **M0-01** _(Infrastructure)_ — Scaffold the package.
  _Verify: `mise run test`._

## M1 tasks

- **M1-01** _(Behavior)_ — Add the only behavior.
  _Depends: M0-01._
  _Verify: `mise run test --filter DECL-01`._
  _Greens: DECL-01._
- **M1-02** _(Gate)_ — Close the milestone.
  _Depends: M1-01._
  _Verify: `mise run test:matrix`._
