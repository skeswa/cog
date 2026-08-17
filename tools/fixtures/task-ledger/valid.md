# Fixture: valid task ledger

A minimal ledger that must pass every `tools/check-task-ledger.mjs` check. It
exercises a cross-milestone dependency, letter-suffixed splits, a recursive
split (`M1-02b` retired into `M1-02ba` and `M1-02bb`), a nested-package lint
test filter, and a gate that names only its immediate prerequisites.

## M0 tasks

- **M0-01** _(Infrastructure)_ — Scaffold the package.
  _Verify: `mise run test`._

## M1 tasks

- **M1-01** _(Decision)_ — Settle the read spelling.
  _Depends: M0-01._
  _Verify: recorded decision._
- **M1-02a** _(Behavior)_ — Add the first behavior.
  _Depends: M1-01._
  _Verify: `mise run test --filter DECL-01`._
  _Greens: DECL-01._
- **M1-02ba** _(Behavior)_ — Add the second behavior.
  _Depends: M1-02a._
  _Verify: `mise run test --filter DECL-02`._
  _Greens: DECL-02._
- **M1-02bb** _(Behavior)_ — Add the third behavior.
  _Depends: M1-02ba._
  _Verify: `mise run test:lint --filter DECL-03`._
  _Greens: DECL-03._
- **M1-03** _(Gate)_ — Close the milestone.
  _Depends: M1-02bb._
  _Verify: `mise run test:matrix`._
