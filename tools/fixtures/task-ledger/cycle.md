# Fixture: cyclic task graph

`M1-02` and `M1-03` depend on each other, so `dependency-cycle` must fire and
report the loop.

## M1 tasks

- **M1-01** _(Infrastructure)_ — Scaffold the package.
  _Verify: `mise run test`._
- **M1-02** _(Behavior)_ — Depend on the task that depends on this one.
  _Depends: M1-03._
  _Verify: `mise run test --filter DECL-01`._
  _Greens: DECL-01._
- **M1-03** _(Behavior)_ — Close the loop.
  _Depends: M1-02._
  _Verify: `mise run test --filter DECL-02`._
  _Greens: DECL-02._
