# Fixture: two release sequences that can interleave

`M1-03` publishes `0.1.0` and `M2-03` publishes `0.2.0`, but the 0.2.0 branch
hangs off the 0.1.0 _candidate gate_ rather than off the 0.1.0 publication.
Neither release reaches the other, so nothing in the graph says which ships
first. `release-chain` reports the pair.

## M0 tasks

- **M0-01** _(Infrastructure)_ — Scaffold the package.
  _Verify: `mise run test`._

## M1 tasks

- **M1-01** _(Behavior)_ — Add the first behavior.
  _Depends: M0-01._
  _Verify: `mise run test --filter DECL-01`._
  _Greens: DECL-01._
- **M1-02** _(Gate)_ — Prepare the non-mutating 0.1.0 release candidate.
  _Depends: M1-01._
  _Verify: `mise run test:matrix`._
- **M1-03** _(Release)_ — Create and push the annotated `0.1.0` tag.
  _Depends: M1-02._
  _Verify: remote tag resolves to the approved commit._

## M2 tasks

- **M2-01** _(Behavior)_ — Add the second behavior.
  _Depends: M1-02._
  _Verify: `mise run test --filter DECL-02`._
  _Greens: DECL-02._
- **M2-02** _(Gate)_ — Prepare the non-mutating 0.2.0 release candidate.
  _Depends: M2-01._
  _Verify: `mise run test:matrix`._
- **M2-03** _(Release)_ — Create and push the annotated `0.2.0` tag.
  _Depends: M2-02._
  _Verify: remote tag resolves to the approved commit._
