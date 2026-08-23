# Fixture: an arena filter that leaves a scenario behind

The M6 arena-integration filters cover `DECL-01` and `DECL-02`, and the M6
section's `_Arena-coverage exceptions:_` note excuses `DECL-03`, but nothing
covers `DECL-04`, so `arena-integration-coverage` must fire for it — and for
it alone.

## M0 tasks

- **M0-01** _(Infrastructure)_ — Scaffold the package.
  _Verify: `mise run test`._

## M1 tasks

- **M1-01** _(Behavior)_ — Add the first behavior.
  _Depends: M0-01._
  _Verify: `mise run test --filter DECL-01`._
  _Greens: DECL-01._
- **M1-02** _(Behavior)_ — Add the second behavior.
  _Depends: M1-01._
  _Verify: `mise run test --filter DECL-02`._
  _Greens: DECL-02._
- **M1-03** _(Behavior)_ — Add the third behavior.
  _Depends: M1-02._
  _Verify: `mise run test --filter DECL-03`._
  _Greens: DECL-03._
- **M1-04** _(Behavior)_ — Add the fourth behavior.
  _Depends: M1-03._
  _Verify: `mise run test --filter DECL-04`._
  _Greens: DECL-04._
- **M1-05** _(Gate)_ — Close the milestone.
  _Depends: M1-04._
  _Verify: `mise run test:matrix`._

## M6 tasks

_Arena-coverage exceptions: DECL-03 stays on the recorded comparison harness
rather than an arena slice filter._

- **M6-01** _(Infrastructure)_ — Re-prove the first two behaviors through the
  arena selector.
  _Depends: M1-05._
  _Verify: `mise run test --filter 'DECL-0[1-2]'`._
- **M6-02** _(Gate)_ — Close the milestone.
  _Depends: M6-01._
  _Verify: `mise run test:matrix`._
