# Fixture: a map row that names a task nobody wrote

The paired plan's M1 closing path names `M1-09`, which no entry defines, so
`plan-task-reference` must fire. A closing path is a pointer into the ledger.

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
