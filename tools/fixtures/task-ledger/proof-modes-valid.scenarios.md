# Fixture scenarios: every proof mode

Each mode the tree defines appears at least once. `PERF-01` carries no marker
at all: group 18 is benchmark-gated in full, so its scenarios take `benchmark`
from the group heading.

- **MODE-01.** The plain host behavior, left unmarked so it takes the `unit`
  default.
- **MODE-02.** The guardrail that has to trap outside debug too. (Proof: exit
  test.)
- **MODE-03.** The mistake the compiler refuses to accept. (Proof: compile-fail.)
- **MODE-04.** The boundary behavior only a device runtime shows.
  (Proof: simulator.)
- **MODE-05.** The behavior the pinned nightly runtime shows.
  (Proof: floor runtime.)
- **MODE-06.** The whole suite passing unchanged. (Proof: suite.)
- **MODE-07.** The guardrails holding outside debug.
  (Proof: release configuration.)

## 18. PERF — Performance guarantees

- **PERF-01.** A steady turn allocates nothing.
