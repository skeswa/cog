# Fixture: infrastructure that owns a scenario

`M1-03` is _(Infrastructure)_ and carries a `_Greens:_` line, so
`misplaced-greens` must fire. Infrastructure unblocks later behavior but
greens no scenario.

## M1 tasks

- **M1-01** _(Infrastructure)_ — Scaffold the package.
  _Verify: `mise run test`._
- **M1-02** _(Behavior)_ — Add the first behavior.
  _Depends: M1-01._
  _Verify: `mise run test --filter DECL-01`._
  _Greens: DECL-01._
- **M1-03** _(Infrastructure)_ — Claim a scenario from infrastructure.
  _Depends: M1-02._
  _Verify: `mise run test --filter DECL-02`._
  _Greens: DECL-02._
- **M1-04** _(Gate)_ — Close the milestone.
  _Depends: M1-03._
  _Verify: `mise run test:matrix`._
