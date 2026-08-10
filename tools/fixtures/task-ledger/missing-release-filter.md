# Fixture: an exit test proven only in debug

`M1-03` greens `TURN-07`, whose proof mode is `exit test`. The scenario says
Cog stops the escaped writer "in every kind of build", so the trap has to be
observed in the release configuration as well as in debug. This `_Verify:_`
names only the debug run, so `exit-test-release` must fire and name the missing
`mise run test:release --filter`.

## M1 tasks

- **M1-01** _(Infrastructure)_ — Scaffold the package.
  _Verify: `mise run test`._
- **M1-02** _(Behavior)_ — Add keyless staging and writer read-back.
  _Depends: M1-01._
  _Verify: `mise run test --filter TURN-01`._
  _Greens: TURN-01._
- **M1-03** _(Behavior)_ — Reject an escaped writer.
  _Depends: M1-02._
  _Verify: `mise run test --filter TURN-07`._
  _Greens: TURN-07._
- **M1-04** _(Gate)_ — Close the milestone.
  _Depends: M1-03._
  _Verify: `mise run test:matrix` and `mise run test:release`._
