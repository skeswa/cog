// The `M9-01` call-site attribution harness. See
// `../../../M9-01-call-site-attribution.md` for the method, and `impl/optimization.md`
// for what it measured.
//
// Every workload runs a fixed number of warm-up iterations, arms the profiler,
// runs exactly the requested number of measured iterations, and disarms it. One
// armed iteration therefore reports one turn's cost rather than an average,
// which is what makes a count of seven allocations attributable to seven lines.

import Cog
import CogTesting
import Darwin

// MARK: - Profiler control

/// Sets the profiler's recording mode: 1 allocations, 2 ARC, 3 both, 0 off.
private typealias ModeFunction = @convention(c) (Int32) -> Void

/// Clears recorded stacks, or prints them.
private typealias VoidFunction = @convention(c) () -> Void

/// The interposer is loaded with `DYLD_INSERT_LIBRARIES` rather than linked, so
/// its controls are resolved at runtime. `RTLD_DEFAULT` is spelled `-2`.
private let interposer = UnsafeMutableRawPointer(bitPattern: -2)

private let modeFunction: ModeFunction? = dlsym(interposer, "cog_prof_mode")
  .map { unsafeBitCast($0, to: ModeFunction.self) }
private let resetFunction: VoidFunction? = dlsym(interposer, "cog_prof_reset")
  .map { unsafeBitCast($0, to: VoidFunction.self) }
private let reportFunction: VoidFunction? = dlsym(interposer, "cog_prof_report")
  .map { unsafeBitCast($0, to: VoidFunction.self) }

/// Discards anything recorded so far and starts recording `mode`.
///
/// Running without the interposer loaded is not an error: every control
/// resolves to `nil` and the workload still runs, which is how the same binary
/// serves `sample` for leaf time.
func armProfiler(_ mode: Int32) {
  resetFunction?()
  modeFunction?(mode)
}

/// Stops recording and prints the aggregated stacks to standard error.
func disarmProfiler() {
  modeFunction?(0)
  reportFunction?()
}

/// Keeps a value alive past the point the optimizer would drop it.
@inline(never)
func blackHole<Value>(_ value: Value) {
  withExtendedLifetime(value) {}
}

// MARK: - Graphs

/// The source a steady turn writes.
let counterSourceCog = Cog<Int>.Manual({ 0 }, name: "prof.counter")

/// One automatic consumer, so a turn actually propagates.
let doubledCog = Cog<Int>({ c in c[counterSourceCog] * 2 }, name: "prof.doubled")

/// The keyed source family the pinned-key workload writes one key of.
let rowSourceCogs = CogBox<Int, Int>.Manual({ 0 }, name: "prof.pinned.source")

/// One automatic consumer per row, so a write reaches a boundary rather than
/// stopping at the source.
let rowCogs = CogBox<Int, Int>(
  { c, key in c[rowSourceCogs[key]] &+ key },
  name: "prof.pinned.row"
)

/// The source at the head of the deep chain.
let chainSourceCog = Cog<Int>.Manual({ 0 }, name: "prof.chain.source")

/// A chain of automatic nodes, each reading the one below it.
///
/// Keyed rather than declared per depth so the chain length is a parameter.
/// This is deliberately **not** the Kairo deep benchmark shape: it isolates
/// per-node settle cost, which that shape does not.
let chainCogs = CogBox<Int, Int>(
  { c, depth in
    depth == 0 ? c[chainSourceCog] : c[chainCogs[depth - 1]] &+ 1
  },
  name: "prof.chain"
)

/// The keyed source family the build workload populates from scratch.
///
/// PERF-03's shape exactly: one keyed source and one keyed automatic consumer per
/// entry, which is how a screen actually reaches a thousand states.
let buildSourceCogs = CogBox<Int, Int>.Manual({ 0 }, name: "prof.build.source")

/// One automatic consumer per built entry.
let buildCogs = CogBox<Int, Int>(
  { c, key in c[buildSourceCogs[key]] &+ key },
  name: "prof.build.entry"
)

// MARK: - Workloads

let arguments = CommandLine.arguments
let workload = arguments.count > 1 ? arguments[1] : "steady"
let mode = Int32(arguments.count > 2 ? Int(arguments[2]) ?? 1 : 1)
let armedIterations = arguments.count > 3 ? Int(arguments[3]) ?? 1 : 1
let parameter = arguments.count > 4 ? Int(arguments[4]) ?? 0 : 0

/// Iterations run before recording starts.
///
/// Enough that first-run costs — lazy metadata, dyld stub binding, array growth
/// to a stable capacity — are behind the measured region, so what it records is
/// the steady state rather than a warm-up.
let warmupIterations = 200

/// Runs `body` through warm-up, then through the armed measured region.
func run(_ body: (Int) -> Void) {
  for iteration in 1...warmupIterations { body(iteration) }
  armProfiler(mode)
  for iteration in 1...armedIterations { body(warmupIterations + iteration) }
  disarmProfiler()
}

/// Builds and releases one fresh context holding `pairs` source-and-automatic pairs.
///
/// The context is local, so it is released before the next iteration begins and
/// each measured iteration reports one complete build rather than a cumulative
/// graph. Reads are the tracked subscript and `peek` in the same combination
/// PERF-03 uses, so the two agree on what "a built state" means.
func buildContext(pairs: Int) {
  let context = Cogs.forTesting()
  for key in 0..<pairs {
    blackHole(context.peek(buildSourceCogs[key]))
    blackHole(context[buildCogs[key]])
  }
  blackHole(context)
}

let cogs = Cogs.forTesting()

switch workload {
case "steady":
  // One write, one tracked read, nothing new. The read is the tracked
  // subscript rather than `peek`, because a peek renews `whileObserved` grace
  // and would measure lifetime machinery instead of a turn (`impl/optimization.md`).
  blackHole(cogs[doubledCog])
  run { iteration in
    cogs.turn(counterSourceCog, to: iteration, name: "prof.turn")
    blackHole(cogs[doubledCog])
  }

case "turn":
  // A write with no read, to separate the turn boundary from the read.
  blackHole(cogs[doubledCog])
  run { iteration in
    cogs.turn(counterSourceCog, to: iteration, name: "prof.turn")
  }

case "read":
  // A tracked read of an already settled value, which should cost nothing.
  blackHole(cogs[doubledCog])
  run { _ in
    blackHole(cogs[doubledCog])
  }

case "pinned":
  // `parameter` rows the UI once read and no longer shows, and one key that is
  // still written and read. Anything that scales with `parameter` is a turn
  // doing work it has no business doing.
  for key in 0..<max(parameter, 1) { blackHole(cogs[rowCogs[key]]) }
  run { iteration in
    cogs.turn(rowSourceCogs[0], to: iteration, name: "prof.pinned.turn")
    blackHole(cogs[rowCogs[0]])
  }

case "deep":
  // One write pulled through `parameter` automatic nodes, so dividing by
  // `parameter` gives per-node settle cost.
  blackHole(cogs[chainCogs[max(parameter, 1)]])
  run { iteration in
    cogs.turn(chainSourceCog, to: iteration, name: "prof.deep.turn")
    blackHole(cogs[chainCogs[max(parameter, 1)]])
  }

case "build":
  // Construction rather than steady state: a *fresh* context each iteration,
  // populated with `parameter` source-and-automatic pairs. Everything the other
  // workloads deliberately push behind their warm-up — slot allocation, column
  // growth, identity filing — is the measured work here, so dividing by twice
  // `parameter` gives the per-state cost of bringing a state into existence.
  //
  // Warm-up is short because one iteration is thousands of states rather than
  // one turn; 200 of them would take minutes and prove nothing extra.
  for _ in 1...2 { buildContext(pairs: max(parameter, 1)) }
  armProfiler(mode)
  for _ in 1...armedIterations { buildContext(pairs: max(parameter, 1)) }
  disarmProfiler()

default:
  fputs("unknown workload \(workload)\n", stderr)
  exit(2)
}
