# Fixture plan: a map row that names another milestone's task

The M1 row closes through `M0-01`, which `plan-cross-milestone-id.md` puts in
M0.

| Plan milestone  | Task ledger                                       | Decisions before dependent work | Closing path     |
| --------------- | ------------------------------------------------- | ------------------------------- | ---------------- |
| M0: Scaffolding | [M0 tasks](./plan-cross-milestone-id.md#m0-tasks) | —                               | `M0-01`          |
| M1: Correctness | [M1 tasks](./plan-cross-milestone-id.md#m1-tasks) | —                               | `M0-01`, `M1-02` |
