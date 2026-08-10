# Fixture: retired split parent beside its descendant

`M1-02` was split into `M1-02a`, which retires `M1-02` as an execution unit,
but the parent is still listed. Executable IDs must be prefix-free, so
`parent-child-coexistence` must fire. `M1-04a` and `M1-04b` are siblings and
must stay silent.

## M1 tasks

- **M1-01** _(Infrastructure)_ — Scaffold the package.
  _Verify: `mise run test`._
- **M1-02** _(Behavior)_ — Keep the retired parent as an execution unit.
  _Depends: M1-01._
  _Verify: `mise run test --filter DECL-01`._
  _Greens: DECL-01._
- **M1-02a** _(Behavior)_ — Add the split child.
  _Depends: M1-01._
  _Verify: `mise run test --filter DECL-02`._
  _Greens: DECL-02._
- **M1-04a** _(Behavior)_ — Add one sibling.
  _Depends: M1-01._
  _Verify: `mise run test --filter DECL-03`._
  _Greens: DECL-03._
- **M1-04b** _(Behavior)_ — Add the other sibling.
  _Depends: M1-04a._
  _Verify: `mise run test --filter DECL-04`._
  _Greens: DECL-04._
