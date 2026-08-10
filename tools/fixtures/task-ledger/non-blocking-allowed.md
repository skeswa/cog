# Fixture: an allowed non-blocking task

`M1-04` is unreachable from the milestone's terminal gate `M1-05` on purpose:
it depends on hosted infrastructure that may be unavailable, and its
`_Non-blocking:_` line records when it executes. This ledger must pass every
check.

## M1 tasks

- **M1-01** _(Infrastructure)_ — Scaffold the package.
  _Verify: `mise run test`._
- **M1-02** _(Behavior)_ — Add the first behavior.
  _Depends: M1-01._
  _Verify: `mise run test --filter DECL-01`._
  _Greens: DECL-01._
- **M1-04** _(Behavior)_ — Add the nightly floor subset.
  _Depends: M1-02._
  _Non-blocking: execute when the pinned floor runtime is available; otherwise
  leave deferred without blocking M1-05 or a release._
  _Verify: a scheduled floor job passes DECL-02._
  _Greens: DECL-02._
- **M1-05** _(Gate)_ — Close the milestone over the host-runnable behavior.
  _Depends: M1-02._
  _Verify: `mise run test:matrix`._
