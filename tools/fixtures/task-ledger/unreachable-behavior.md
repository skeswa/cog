# Fixture: behavior no gate covers

`M1-04` is a behavior task the milestone's terminal gate `M1-05` does not
transitively depend on, and it carries no `_Non-blocking:_` policy, so
`unreachable-behavior` must fire. Closing M1 would never run it.

## M1 tasks

- **M1-01** _(Infrastructure)_ — Scaffold the package.
  _Verify: `mise run test`._
- **M1-02** _(Behavior)_ — Add the first behavior.
  _Depends: M1-01._
  _Verify: `mise run test --filter DECL-01`._
  _Greens: DECL-01._
- **M1-04** _(Behavior)_ — Add a behavior nothing closes over.
  _Depends: M1-02._
  _Verify: `mise run test --filter DECL-02`._
  _Greens: DECL-02._
- **M1-05** _(Gate)_ — Close the milestone over the first behavior only.
  _Depends: M1-02._
  _Verify: `mise run test:matrix`._
