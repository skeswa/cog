# Fixture: an arena filter that leaves a scenario behind

M6 re-proves M1's behavior under the arena core, but its one arena filter
selects `DECL-01` and `DECL-02` only. `DECL-04` is excepted by the milestone's
arena-coverage note, which the check parses instead of assuming. `DECL-03` is
neither filtered nor excepted, so it would keep its simple-core-only proof
while M6 replaced the core underneath it. `arena-integration-coverage` reports
the hole.

The note's `M6-01` and `M6-02` mentions sit in code spans and have a scenario
ID's shape; a parser that read them as scenarios would except the wrong thing.

## M0 tasks

- **M0-01** _(Infrastructure)_ — Scaffold the package.
  _Verify: `mise run test`._

## M1 tasks

- **M1-01** _(Behavior)_ — Add the first behavior.
  _Depends: M0-01._
  _Verify: `mise run test --filter DECL-01`._
  _Greens: DECL-01._
- **M1-02** _(Behavior)_ — Add the second behavior.
  _Depends: M1-01._
  _Verify: `mise run test --filter DECL-02`._
  _Greens: DECL-02._
- **M1-03** _(Behavior)_ — Add the third behavior.
  _Depends: M1-02._
  _Verify: `mise run test --filter DECL-03`._
  _Greens: DECL-03._
- **M1-04** _(Behavior)_ — Add the fourth behavior.
  _Depends: M1-03._
  _Verify: `mise run test --filter DECL-04`._
  _Greens: DECL-04._
- **M1-05** _(Gate)_ — Close the milestone.
  _Depends: M1-04._
  _Verify: `mise run test:matrix`._

## M6 tasks

_Arena-coverage exceptions: DECL-04 is proven under the arena core by the
`M6-02` edge gate rather than an `M6-01` filter._

- **M6-01** _(Infrastructure)_ — Pass the declaration behavior through the
  arena selector.
  _Depends: M1-05._
  _Verify: `COG_TEST_CORE=arena mise run test --filter
'DECL-01|DECL-02'`._
- **M6-02** _(Gate)_ — Run the complete M1 scenario set under the arena core.
  _Depends: M6-01._
  _Verify: the complete M1 scenario set with `COG_TEST_CORE=arena`._
