# Fixture: two tasks green one scenario

`M1-02` and `M1-03` both green `DECL-02`, so `duplicate-scenario-owner` must
fire and name both owners. Every scenario appears in exactly one `_Greens:_`
line.

## M1 tasks

- **M1-01** _(Infrastructure)_ — Scaffold the package.
  _Verify: `mise run test`._
- **M1-02** _(Behavior)_ — Add both behaviors.
  _Depends: M1-01._
  _Verify: `mise run test --filter 'DECL-01|DECL-02'`._
  _Greens: DECL-01, DECL-02._
- **M1-03** _(Behavior)_ — Claim the second behavior again.
  _Depends: M1-02._
  _Verify: `mise run test --filter DECL-02`._
  _Greens: DECL-02._
- **M1-04** _(Gate)_ — Close the milestone.
  _Depends: M1-03._
  _Verify: `mise run test:matrix`._
