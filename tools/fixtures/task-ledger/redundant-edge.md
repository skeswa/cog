# Fixture: dependency list that is not transitively minimal

`M1-03` lists both `M1-01` and `M1-02`, but `M1-02` already depends on
`M1-01`. `_Depends:_` names only immediate prerequisites, so
`redundant-dependency` must fire and report the implying path.

## M1 tasks

- **M1-01** _(Infrastructure)_ — Scaffold the package.
  _Verify: `mise run test`._
- **M1-02** _(Behavior)_ — Add the first behavior.
  _Depends: M1-01._
  _Verify: `mise run test --filter DECL-01`._
  _Greens: DECL-01._
- **M1-03** _(Gate)_ — Close the milestone with a redundant edge.
  _Depends: M1-01, M1-02._
  _Verify: `mise run test:matrix`._
