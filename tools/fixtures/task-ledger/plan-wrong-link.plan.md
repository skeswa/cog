# Fixture plan: a map row that links to the wrong section

The M1 row points at `#m1-task`, which no heading in `plan-wrong-link.md`
produces.

| Plan milestone  | Task ledger                               | Decisions before dependent work | Closing path |
| --------------- | ----------------------------------------- | ------------------------------- | ------------ |
| M0: Scaffolding | [M0 tasks](./plan-wrong-link.md#m0-tasks) | —                               | `M0-01`      |
| M1: Correctness | [M1 tasks](./plan-wrong-link.md#m1-task)  | —                               | `M1-02`      |
