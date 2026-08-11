# Fixture plan: two gates with no closing path

The milestone map `ambiguous-milestone-gate.md` is checked against. Every milestone the
ledger defines has one row here, and each row links to that milestone's task
section.

| Plan milestone  | Task ledger                                        | Decisions before dependent work | Closing path          |
| --------------- | -------------------------------------------------- | ------------------------------- | --------------------- |
| M1: Correctness | [M1 tasks](./ambiguous-milestone-gate.md#m1-tasks) | —                               | `M1-03`, then `M1-04` |
