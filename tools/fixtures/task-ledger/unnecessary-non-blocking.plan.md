# Fixture plan: a non-blocking task the gate already covers

The milestone map `unnecessary-non-blocking.md` is checked against. Every milestone the
ledger defines has one row here, and each row links to that milestone's task
section.

| Plan milestone  | Task ledger                                        | Decisions before dependent work | Closing path                                             |
| --------------- | -------------------------------------------------- | ------------------------------- | -------------------------------------------------------- |
| M1: Correctness | [M1 tasks](./unnecessary-non-blocking.md#m1-tasks) | —                               | `M1-05`; `M1-04` is non-blocking without a floor runtime |
