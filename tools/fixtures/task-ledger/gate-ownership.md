# Fixture: a gate that owns a scenario it may not own

`M1-03` is the milestone's gate. Greening `LEG-01`, whose proof mode is
`suite`, is exactly what a gate is for. Greening `DECL-02`, a plain `unit`
scenario, is not: a gate proves a slice whole and never owns the repairs it
discovers, so one behavior's promise belongs to a behavior task.
`gate-proof-mode` must fire for `DECL-02` and stay quiet about `LEG-01`.

## M1 tasks

- **M1-01** _(Infrastructure)_ — Scaffold the package.
  _Verify: `mise run test`._
- **M1-02** _(Behavior)_ — Add the first behavior.
  _Depends: M1-01._
  _Verify: `mise run test --filter DECL-01`._
  _Greens: DECL-01._
- **M1-03** _(Gate)_ — Close the milestone and pick up a loose behavior on the
  way past.
  _Depends: M1-02._
  _Verify: `mise run test:matrix`._
  _Greens: DECL-02, LEG-01._
