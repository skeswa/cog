#!/usr/bin/env node

// Compares the local CogLint artifact with its command plugin across every
// reporter and both explicit target roles.

import { spawnSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdirSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

/** The repository root, resolved from this script so cwd never matters. */
const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));

/** Stable ignored scratch package retained for a parity failure inspection. */
const TEST_ROOT = join(REPO_ROOT, ".build", "coglint-command-plugin");

/** The generated local artifact and checked-in command-plugin source under test. */
const BUNDLE_NAME = "CogLintBinary.artifactbundle";
const BUNDLE_PATH = join(REPO_ROOT, "swift", "Lint", "Artifacts", BUNDLE_NAME);
const ARCHIVE_PATH = `${BUNDLE_PATH}.zip`;
const PLUGIN_SOURCE = join(
  REPO_ROOT,
  "swift",
  "Lint",
  "Plugins",
  "CogLintCommandPlugin",
  "plugin.swift",
);

/** One primitive violation that the explicit test role exempts. */
const SOURCE_PATH = join("Sources", "Feature.swift");
const VIOLATING_SOURCE = "func drive(_ c: Writer) { c.refresh(forecastCog) }\n";
const RULE = "primitives-only-in-ops";
const REPORTERS = ["xcode", "github", "sarif"];
const TARGET_ROLES = ["production", "test"];

main();

/** Creates one consumer and requires bare-versus-plugin parity for the full matrix. */
function main() {
  if (process.platform !== "darwin" || process.arch !== "arm64") {
    fail("LINT-18 requires the accepted Apple Silicon plugin test host");
  }

  ensureCurrentArtifact();
  rmSync(TEST_ROOT, { force: true, recursive: true });
  writeConsumer();

  for (const targetRole of TARGET_ROLES) {
    for (const reporter of REPORTERS) {
      verifyParity(targetRole, reporter);
    }
  }

  console.log(
    "\nPASS LINT-18: command plugin matched the bare CLI for both roles and all reporters",
  );
}

/** Rebuilds when any source, pin, manifest, or builder is newer than the archive. */
function ensureCurrentArtifact() {
  const inputs = [
    join(REPO_ROOT, "swift", "Lint", "Package.swift"),
    join(REPO_ROOT, "swift", "Lint", "Package.resolved"),
    join(REPO_ROOT, "swift", "Lint", "Sources"),
    join(REPO_ROOT, "tools", "build-coglint-artifact.mjs"),
  ];
  const latestInput = Math.max(...inputs.map(latestModificationTime));
  if (!existsSync(ARCHIVE_PATH) || statSync(ARCHIVE_PATH).mtimeMs < latestInput) {
    runSuccessful(process.execPath, [join(REPO_ROOT, "tools", "build-coglint-artifact.mjs")], {
      stdio: "inherit",
    });
  } else {
    console.log("==> Reusing the artifact built from the current CogLint sources");
  }
}

/** Finds the newest regular file below one input path. */
function latestModificationTime(path) {
  const status = statSync(path);
  if (!status.isDirectory()) return status.mtimeMs;
  return Math.max(
    status.mtimeMs,
    ...readdirSync(path).map((entry) => latestModificationTime(join(path, entry))),
  );
}

/** Writes the binary target, command product, and source fixture into one package. */
function writeConsumer() {
  const pluginDirectory = join(TEST_ROOT, "Plugins", "CogLintCommandPlugin");
  mkdirSync(pluginDirectory, { recursive: true });
  mkdirSync(join(TEST_ROOT, "Sources"), { recursive: true });
  cpSync(BUNDLE_PATH, join(TEST_ROOT, BUNDLE_NAME), { recursive: true });
  cpSync(PLUGIN_SOURCE, join(pluginDirectory, "plugin.swift"));
  writeFileSync(join(TEST_ROOT, SOURCE_PATH), VIOLATING_SOURCE);
  writeFileSync(
    join(TEST_ROOT, "Package.swift"),
    `// swift-tools-version:6.2

import PackageDescription

let package = Package(
  name: "CogLintCommandPluginConsumer",
  platforms: [.macOS(.v14)],
  products: [
    .plugin(name: "CogLintCommandPlugin", targets: ["CogLintCommandPlugin"]),
  ],
  targets: [
    .binaryTarget(name: "CogLintBinary", path: "${BUNDLE_NAME}"),
    .plugin(
      name: "CogLintCommandPlugin",
      capability: .command(
        intent: .custom(
          verb: "coglint",
          description: "Check Swift sources against Cog conventions"
        ),
        permissions: []
      ),
      dependencies: ["CogLintBinary"]
    ),
  ]
)
`,
  );
}

/** Requires one role and reporter to produce the same output and status both ways. */
function verifyParity(targetRole, reporter) {
  console.log(`\n==> Command plugin parity: ${targetRole}/${reporter}`);
  const tool = join(TEST_ROOT, BUNDLE_NAME, "coglint-arm64-apple-macosx", "bin", "coglint");
  const forwarded = [SOURCE_PATH, "--target-role", targetRole, "--reporter", reporter];
  const bare = runCaptured(tool, forwarded, { cwd: TEST_ROOT });
  const plugin = runCaptured(
    "swift",
    [
      "package",
      "--package-path",
      TEST_ROOT,
      "--scratch-path",
      join(TEST_ROOT, ".build"),
      "coglint",
      ...forwarded,
    ],
    { cwd: TEST_ROOT },
  );

  if (plugin.status !== bare.status) {
    fail(`${targetRole}/${reporter} status differs: bare ${bare.status}, plugin ${plugin.status}`);
  }
  if (plugin.stdout !== bare.stdout) {
    fail(`${targetRole}/${reporter} stdout differs between the bare CLI and plugin`);
  }

  if (targetRole === "test") {
    if (bare.status !== 0) {
      fail(`${reporter} did not honor the test-role primitive exemption`);
    }
    if (reporter === "sarif") {
      const log = JSON.parse(bare.stdout);
      if (log.runs?.[0]?.results?.length !== 0) {
        fail("clean SARIF output contains a result under the test role");
      }
    } else if (bare.stdout !== "") {
      fail(`clean ${reporter} output is not empty under the test role`);
    }
  } else {
    if (bare.status === 0 || !bare.stdout.includes(RULE)) {
      fail(`${reporter} did not report the production primitive violation`);
    }
    validateReporterPayload(reporter, bare.stdout);
  }
  console.log(`==> ${targetRole}/${reporter}: status ${bare.status}, stdout parity confirmed`);
}

/** Requires the reporter-specific grammar around the shared production finding. */
function validateReporterPayload(reporter, output) {
  switch (reporter) {
    case "xcode":
      if (!output.includes(`${SOURCE_PATH}:1:29: error: [${RULE}]`)) {
        fail("Xcode reporter lost the exact source region or rule slug");
      }
      break;
    case "github":
      if (!output.startsWith(`::error file=${SOURCE_PATH},line=1,col=29,title=${RULE}::`)) {
        fail("GitHub reporter lost its workflow-command fields");
      }
      break;
    case "sarif": {
      const log = JSON.parse(output);
      const result = log.runs?.[0]?.results?.[0];
      if (
        result?.ruleId !== RULE ||
        result?.locations?.[0]?.physicalLocation?.region?.startColumn !== 29
      ) {
        fail("SARIF reporter lost its rule or exact source region");
      }
      break;
    }
    default:
      fail(`unknown reporter in parity suite: ${reporter}`);
  }
}

/** Runs one invocation while retaining stdout separately from framework logs. */
function runCaptured(command, arguments_, options = {}) {
  const result = spawnSync(command, arguments_, {
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
    ...options,
  });
  if (result.error !== undefined) {
    fail(`could not run ${command}: ${result.error.message}`);
  }
  if (result.signal !== null && result.signal !== undefined) {
    fail(`${command} was killed by ${result.signal}`);
  }
  return result;
}

/** Runs one required successful subprocess. */
function runSuccessful(command, arguments_, options = {}) {
  const result = spawnSync(command, arguments_, {
    maxBuffer: 32 * 1024 * 1024,
    ...options,
  });
  if (result.error !== undefined) {
    fail(`could not run ${command}: ${result.error.message}`);
  }
  if (result.signal !== null && result.signal !== undefined) {
    fail(`${command} was killed by ${result.signal}`);
  }
  if (result.status !== 0) {
    fail(`${command} exited with status ${result.status}`);
  }
  return result;
}

/** Reports one parity failure without allowing a shared nonzero status to look green. */
function fail(message) {
  console.error(`error: coglint command-plugin test: ${message}`);
  process.exit(1);
}
