# Cog benchmarks

A **separate SwiftPM package**, not a target of the root one. That is the whole
design of this directory.

SwiftPM hands a package's dependencies to everyone who resolves it, so a
benchmark harness, an allocator backend, or a baseline-checking CLI added to the
root manifest would land in the dependency graph of every app that adds Cog. The
root package resolves with **no dependencies at all** — swift-docc-plugin is
gated behind `COG_DOCC=1` for exactly the same reason — and that is a shipped
property of the library rather than a tidiness preference.

The relationship runs one way only. This package depends on the root by path;
nothing in the root manifest references this directory. `M5-05a` proved it by
describing both manifests:

```console
$ swift package show-dependencies --format json          # root
cog

$ swift package --package-path swift/Benchmarks show-dependencies --format json
benchmarks
  cog
```

The dependency is a **path**, never a version. Benchmarks measure the working
tree, so resolving Cog from a tag would make every measurement a statement about
a commit that is not the one being changed.

## Running it

From this directory:

```console
swift run -c release CogBenchmarks
```

Always release. A debug measurement of a graph library measures the optimizer's
absence.

`mise run bench` wraps this from the repository root once `M5-08b` adds it.

## What is here today

A shell. It runs one small instance of each shared scenario and prints the run
count against the count the shape requires:

```text
COUNT-01-KairoDiamond [inline]: 66/66 runs (exact), value 55
COUNT-06-CellxLattice [inline]: 800/800 runs (exact), value 156298667222685
```

Running scenarios rather than printing a greeting is deliberate: the thing that
has to keep working is that benchmarks and `CogScenarioTests` drive the _same_
graphs, out of `_CogScenarios`. A run-count assertion and a timing measurement
that disagreed about which graph they ran would make both meaningless.

The numbers it prints are not measurements. They have no pinned environment
behind them, and nothing here gates on them yet.

## What is coming

| Task               | Adds                                                                                                       |
| ------------------ | ---------------------------------------------------------------------------------------------------------- |
| `M5-05ba`          | verified pins: benchmark package repository and minimum version, exact ARC metric names, baseline CLI      |
| `M5-05bb`          | allocator behavior across Swift 6.2/6.3, MainActor compatibility, VM-versus-bare-metal noise on the runner |
| `M5-05c`           | the pinned dependency, the selected allocator configuration, and one real MainActor benchmark              |
| `M5-06`            | zero-allocation steady-turn and `box[key]` creation benchmarks                                             |
| `M5-07a`–`M5-07d`  | ARC traffic, peak memory, boundary-object counts, pinned-key notice traffic                                |
| `M5-08a`, `M5-08b` | pinned-environment baselines, `mise run bench`, and the non-gating `bench-build` CI job                    |

Per-callsite ARC attribution stays a manual `xcrun xctrace` workflow, documented
here when `M5-07a` establishes it.
