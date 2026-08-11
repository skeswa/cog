# Fixture: a non-blocking task the plan never names

`M1-04` carries a well-formed `_Non-blocking:_` policy, so M1 can close
without it. The paired plan's M1 row never says so, and `plan-non-blocking-row`
must fire: dropping work from a closing path is the plan's decision to record.

## M0 tasks

- **M0-01** _(Infrastructure)_ — Scaffold the package.
  _Verify: `mise run test`._

## M1 tasks

- **M1-01** _(Behavior)_ — Add the host-runnable behavior.
  _Depends: M0-01._
  _Verify: `mise run test --filter DECL-01`._
  _Greens: DECL-01._
- **M1-04** _(Behavior)_ — Add the nightly floor subset.
  _Depends: M1-01._
  _Non-blocking: execute when the pinned floor runtime is available; otherwise
  leave deferred without blocking M1-05 or a release._
  _Verify: a scheduled floor job passes DECL-02._
  _Greens: DECL-02._
- **M1-05** _(Gate)_ — Close the milestone over the host-runnable behavior.
  _Depends: M1-01._
  _Verify: `mise run test:matrix`._
