# Fixture: a scenario no task owns

The census defines `DECL-03`, but no `_Greens:_` line claims it, so
`unowned-scenario` must fire and point at the scenario's own line.

## M1 tasks

- **M1-01** _(Infrastructure)_ — Scaffold the package.
  _Verify: `mise run test`._
- **M1-02** _(Behavior)_ — Add the first behavior.
  _Depends: M1-01._
  _Verify: `mise run test --filter DECL-01`._
  _Greens: DECL-01._
- **M1-03** _(Behavior)_ — Add the second behavior.
  _Depends: M1-02._
  _Verify: `mise run test --filter DECL-02`._
  _Greens: DECL-02._
- **M1-04** _(Gate)_ — Close the milestone.
  _Depends: M1-03._
  _Verify: `mise run test:matrix`._
