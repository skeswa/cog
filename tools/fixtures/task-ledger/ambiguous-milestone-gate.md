# Fixture: two gates with no closing path

M1's gates `M1-03` and `M1-04` are independent — neither depends on the other
— so the milestone has no terminal gate and `milestone-gate` must fire. Gates
of one milestone form a closing path.

## M1 tasks

- **M1-01** _(Infrastructure)_ — Scaffold the package.
  _Verify: `mise run test`._
- **M1-02** _(Behavior)_ — Add the only behavior.
  _Depends: M1-01._
  _Verify: `mise run test --filter DECL-01`._
  _Greens: DECL-01._
- **M1-03** _(Gate)_ — Prove the behavior one way.
  _Depends: M1-02._
  _Verify: `mise run test:matrix`._
- **M1-04** _(Gate)_ — Prove the behavior another way.
  _Depends: M1-02._
  _Verify: `mise run test:release`._
