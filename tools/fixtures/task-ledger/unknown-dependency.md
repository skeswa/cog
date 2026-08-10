# Fixture: dependency on a task that does not exist

`M1-02` depends on `M1-09`, which no entry defines, so `unknown-dependency`
must fire.

## M1 tasks

- **M1-01** _(Infrastructure)_ — Scaffold the package.
  _Verify: `mise run test`._
- **M1-02** _(Behavior)_ — Depend on a task nobody wrote.
  _Depends: M1-01, M1-09._
  _Verify: `mise run test --filter DECL-01`._
  _Greens: DECL-01._
