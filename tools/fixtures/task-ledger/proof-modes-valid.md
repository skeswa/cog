# Fixture: every proof mode, proven the right way

One ledger that uses all eight proof modes correctly, so a proof-mode check
that went vacuous — or that grew stricter than the tree promises — fails here
rather than only on the real ledger. The behavior filters expand to exactly
their unit- and exit-test greens; the exit test runs in debug and release; the
compile-fail scenario batches through `test:compilefail`; the simulator, floor,
and benchmark scenarios name the runs that prove them; and the gate greens only
the suite- and release-configuration scenarios a whole run can show.

## M1 tasks

- **M1-01** _(Infrastructure)_ — Scaffold the package.
  _Verify: `mise run test`._
- **M1-02** _(Behavior)_ — Add the read-only projection and its rejected-writer
  fixture.
  _Depends: M1-01._
  _Verify: `mise run test --filter MODE-01` and `mise run test:compilefail`._
  _Greens: MODE-01, MODE-03._
- **M1-03** _(Behavior)_ — Reject an escaped writer in debug and release.
  _Depends: M1-02._
  _Verify: `mise run test --filter MODE-02` and
  `mise run test:release --filter MODE-02`._
  _Greens: MODE-02._
- **M1-04** _(Behavior)_ — Prove the UIKit boundary on a device runtime and on
  the pinned floor.
  _Depends: M1-02._
  _Verify: simulator `CogBoundaryTests` filtered to MODE-04, and a nightly floor
  job passing MODE-05._
  _Greens: MODE-04, MODE-05._
- **M1-05** _(Behavior)_ — Measure the steady turn's allocations.
  _Depends: M1-02._
  _Verify: benchmark filter for PERF-01 plus the recorded `perf.md` result._
  _Greens: PERF-01._
- **M1-06** _(Gate)_ — Close the milestone across the matrix and the release
  configuration.
  _Depends: M1-03, M1-04, M1-05._
  _Verify: `mise run test:matrix` and `mise run test:release`._
  _Greens: MODE-06, MODE-07._
