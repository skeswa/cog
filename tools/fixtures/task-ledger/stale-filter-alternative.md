# Fixture: a filter alternative left behind by a retired scenario

`M1-01`'s filter still names `DECL-99`, which matches no census scenario, so
`stale-filter-alternative` must fire — while `filter-expansion` stays quiet,
because the dead alternative contributes nothing to the union and the
surviving alternative expands to exactly the task's greens.

## M0 tasks

- **M0-01** _(Infrastructure)_ — Scaffold the package.
  _Verify: `mise run test`._

## M1 tasks

- **M1-01** _(Behavior)_ — Add the first behavior.
  _Depends: M0-01._
  _Verify: `mise run test --filter 'DECL-01|DECL-99'`._
  _Greens: DECL-01._
- **M1-02** _(Gate)_ — Close the milestone.
  _Depends: M1-01._
  _Verify: `mise run test:matrix`._
