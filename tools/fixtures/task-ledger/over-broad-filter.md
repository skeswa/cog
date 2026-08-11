# Fixture: a filter that runs more than the task claims

`M1-02` claims `DECL-01` and `DECL-02`, but its filter `DECL-0[1-3]` also
selects `DECL-03`, which `M1-03` owns. The claim reads as if the two tasks were
independent while the earlier one cannot go green without the later one's work,
and a scenario added to the class later would be swept in silently.
`filter-expansion` must fire and name `DECL-03` as the extra selection.

## M1 tasks

- **M1-01** _(Infrastructure)_ — Scaffold the package.
  _Verify: `mise run test`._
- **M1-02** _(Behavior)_ — Add the first two behaviors.
  _Depends: M1-01._
  _Verify: `mise run test --filter 'DECL-0[1-3]'`._
  _Greens: DECL-01, DECL-02._
- **M1-03** _(Behavior)_ — Add the third behavior.
  _Depends: M1-02._
  _Verify: `mise run test --filter DECL-03`._
  _Greens: DECL-03._
- **M1-04** _(Gate)_ — Close the milestone.
  _Depends: M1-03._
  _Verify: `mise run test:matrix`._
