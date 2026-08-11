# Fixture: a green that names no scenario

`M1-03` greens `DECL-09`, which the scenario tree does not define, so
`unknown-scenario` must fire.

## M1 tasks

- **M1-01** _(Infrastructure)_ — Scaffold the package.
  _Verify: `mise run test`._
- **M1-02** _(Behavior)_ — Add the first behavior.
  _Depends: M1-01._
  _Verify: `mise run test --filter DECL-01`._
  _Greens: DECL-01._
- **M1-03** _(Behavior)_ — Claim a scenario nobody wrote.
  _Depends: M1-02._
  _Verify: `mise run test --filter 'DECL-02|DECL-09'`._
  _Greens: DECL-02, DECL-09._
- **M1-04** _(Gate)_ — Close the milestone.
  _Depends: M1-03._
  _Verify: `mise run test:matrix`._
