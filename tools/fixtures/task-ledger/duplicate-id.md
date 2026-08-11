# Fixture: duplicate task ID

`M1-02a` is defined twice, so `duplicate-task-id` must fire. Task IDs are
never renumbered or reused.

## M1 tasks

- **M1-01** _(Infrastructure)_ — Scaffold the package.
  _Verify: `mise run test`._
- **M1-02a** _(Behavior)_ — Add the first behavior.
  _Depends: M1-01._
  _Verify: `mise run test --filter DECL-01`._
  _Greens: DECL-01._
- **M1-02a** _(Behavior)_ — Reuse an already-taken ID.
  _Depends: M1-01._
  _Verify: `mise run test --filter DECL-02`._
  _Greens: DECL-02._
- **M1-03** _(Gate)_ — Close the milestone.
  _Depends: M1-02a._
  _Verify: `mise run test:matrix`._
