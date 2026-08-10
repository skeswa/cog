# Fixture: a map row that links to the wrong section

The paired plan's M1 row links to an anchor the ledger does not define, so
`plan-task-link` must fire. The link is how a reader crosses from milestone
intent to the tasks that execute it.

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
