# Fixture: a non-blocking task the gate already covers

`M1-04` carries a well-formed `_Non-blocking:_` policy, but the milestone's
terminal gate `M1-05` depends on it, so the task blocks the milestone whatever
the line claims and `unnecessary-non-blocking` must fire.

## M1 tasks

- **M1-01** _(Infrastructure)_ — Scaffold the package.
  _Verify: `mise run test`._
- **M1-02** _(Behavior)_ — Add the first behavior.
  _Depends: M1-01._
  _Verify: `mise run test --filter DECL-01`._
  _Greens: DECL-01._
- **M1-04** _(Behavior)_ — Add a behavior the gate waits on anyway.
  _Depends: M1-02._
  _Non-blocking: execute when the pinned floor runtime is available._
  _Verify: `mise run test --filter DECL-02`._
  _Greens: DECL-02._
- **M1-05** _(Gate)_ — Close the milestone over both behaviors.
  _Depends: M1-04._
  _Verify: `mise run test:matrix`._
