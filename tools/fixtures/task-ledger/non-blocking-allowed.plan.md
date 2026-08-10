# Fixture plan: an allowed non-blocking task

The milestone map `non-blocking-allowed.md` is checked against. Every milestone the
ledger defines has one row here, and each row links to that milestone's task
section.

| Plan milestone  | Task ledger                                    | Decisions before dependent work | Closing path                                             |
| --------------- | ---------------------------------------------- | ------------------------------- | -------------------------------------------------------- |
| M1: Correctness | [M1 tasks](./non-blocking-allowed.md#m1-tasks) | —                               | `M1-05`; `M1-04` is non-blocking without a floor runtime |
