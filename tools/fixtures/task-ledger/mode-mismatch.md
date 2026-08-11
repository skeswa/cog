# Fixture: a proof mode its verification never uses

`M1-02` greens `DECL-06`, whose proof mode is `compile-fail`, but its
`_Verify:_` only runs the host filter that proves `DECL-05`. Compile-fail
fixtures live outside every SwiftPM target and are type-checked in one batched
`swiftc` pass, so nothing a `--filter` selects can turn `DECL-06` green:
`proof-mode-command` must fire and name the missing command.

## M1 tasks

- **M1-01** _(Infrastructure)_ — Scaffold the package.
  _Verify: `mise run test`._
- **M1-02** _(Behavior)_ — Add the read-only projection and its rejected-writer
  fixture.
  _Depends: M1-01._
  _Verify: `mise run test --filter DECL-05`._
  _Greens: DECL-05, DECL-06._
- **M1-03** _(Gate)_ — Close the milestone.
  _Depends: M1-02._
  _Verify: `mise run test:matrix`._
