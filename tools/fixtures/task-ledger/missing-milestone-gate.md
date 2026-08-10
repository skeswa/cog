# Fixture: a milestone with behavior and no gate

M1 has behavior tasks but no `_(Gate)_` task, so reachability has no anchor
and `milestone-gate` must fire. M0 has no behavior and needs no gate.

## M0 tasks

- **M0-01** _(Infrastructure)_ — Scaffold the package.
  _Verify: `mise run test`._

## M1 tasks

- **M1-02** _(Behavior)_ — Add the first behavior.
  _Depends: M0-01._
  _Verify: `mise run test --filter DECL-01`._
  _Greens: DECL-01._
