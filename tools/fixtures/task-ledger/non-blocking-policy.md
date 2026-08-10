# Fixture: a non-blocking line that states no policy

`M1-04` claims the non-blocking exception without saying when it executes, so
`non-blocking-policy` must fire. The exception is only meaningful with an
external-availability policy attached.

## M1 tasks

- **M1-01** _(Infrastructure)_ — Scaffold the package.
  _Verify: `mise run test`._
- **M1-02** _(Behavior)_ — Add the first behavior.
  _Depends: M1-01._
  _Verify: `mise run test --filter DECL-01`._
  _Greens: DECL-01._
- **M1-04** _(Behavior)_ — Add the nightly floor subset.
  _Depends: M1-02._
  _Non-blocking: deferred for now._
  _Verify: a scheduled floor job passes DECL-02._
  _Greens: DECL-02._
- **M1-05** _(Gate)_ — Close the milestone over the host-runnable behavior.
  _Depends: M1-02._
  _Verify: `mise run test:matrix`._
