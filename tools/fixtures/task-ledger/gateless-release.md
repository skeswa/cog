# Fixture: a publication no gate stands behind

`M1-03` pushes the `0.1.0` tag straight off a changelog task. The milestone's
gate `M1-04` sits beside the release rather than upstream of it, so the tag
would be published without a release candidate ever having been proven.
`release-after-gate` reports the release.

## M0 tasks

- **M0-01** _(Infrastructure)_ — Scaffold the package.
  _Verify: `mise run test`._

## M1 tasks

- **M1-01** _(Behavior)_ — Add the first behavior.
  _Depends: M0-01._
  _Verify: `mise run test --filter DECL-01`._
  _Greens: DECL-01._
- **M1-02** _(Infrastructure)_ — Draft the changelog and release notes.
  _Depends: M1-01._
  _Verify: reviewed changelog entry._
- **M1-03** _(Release)_ — Create and push the annotated `0.1.0` tag.
  _Depends: M1-02._
  _Verify: remote tag resolves to the approved commit._
- **M1-04** _(Gate)_ — Close the milestone.
  _Depends: M1-01._
  _Verify: `mise run test:matrix`._
