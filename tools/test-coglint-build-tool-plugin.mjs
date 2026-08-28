#!/usr/bin/env node

// Exercises the local CogLint artifact through its build-tool plugin in real
// SwiftPM and Xcode consumers, including unchanged-input cache replay.

import { spawnSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  BUILD_TOOL_PLUGIN,
  BUNDLE_NAME,
  BUNDLE_PATH,
  PLUGINS_PACKAGE_NAME,
  consumerManifest,
  ensureCurrentArtifact,
  pluginSourcePath,
} from "./lib/coglint-artifact.mjs";

/** The repository root, resolved from this script so cwd never matters. */
const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));

/** Stable ignored scratch space retained for failed-build inspection. */
const TEST_ROOT = join(REPO_ROOT, ".build", "coglint-build-tool-plugin");

/** One unambiguous production-rule finding shared by both consumers. */
const VIOLATING_SOURCE = "let countSourceCog = Cog.Manual(0)\n";
const DIAGNOSTIC_FRAGMENT =
  "Feature.swift:1:5: error: [manual-cog-private] writable Cog sources must be `private` or `fileprivate`; expose `.readOnly` or an automatic cog";

main();

/** Builds the current artifact and proves fresh plus cached plugin behavior. */
function main() {
  if (process.platform !== "darwin" || process.arch !== "arm64") {
    fail("LINT-17 requires the accepted Apple Silicon plugin test host");
  }

  ensureCurrentArtifact(fail);
  rmSync(TEST_ROOT, { force: true, recursive: true });
  mkdirSync(TEST_ROOT, { recursive: true });

  const distribution = writeDistributionPackage();
  const swiftPMConsumer = writeSwiftPMConsumer(distribution);
  verifySwiftPMConsumer(swiftPMConsumer);

  const xcodeConsumer = writeXcodeConsumer(distribution);
  verifyXcodeConsumer(xcodeConsumer);

  console.log(
    "\nPASS LINT-17: SwiftPM and Xcode replayed identical diagnostics from the plugin cache",
  );
}

/** Creates the local binary target and plugin product consumed by both hosts. */
function writeDistributionPackage() {
  const directory = join(TEST_ROOT, PLUGINS_PACKAGE_NAME);
  const pluginDirectory = join(directory, "Plugins", BUILD_TOOL_PLUGIN.name);
  mkdirSync(pluginDirectory, { recursive: true });
  cpSync(BUNDLE_PATH, join(directory, BUNDLE_NAME), { recursive: true });
  cpSync(pluginSourcePath(BUILD_TOOL_PLUGIN.name), join(pluginDirectory, "plugin.swift"));
  writeFileSync(
    join(directory, "Package.swift"),
    consumerManifest({
      name: PLUGINS_PACKAGE_NAME,
      binaryTarget: { path: BUNDLE_NAME },
      plugins: [BUILD_TOOL_PLUGIN],
    }),
  );
  return directory;
}

/** Creates a source package that applies the local plugin product to one target. */
function writeSwiftPMConsumer(distribution) {
  const directory = join(TEST_ROOT, "SwiftPMConsumer");
  const sourceDirectory = join(directory, "Sources", "ViolatingFeature");
  mkdirSync(sourceDirectory, { recursive: true });
  writeFileSync(join(sourceDirectory, "Feature.swift"), VIOLATING_SOURCE);
  writeFileSync(
    join(directory, "Package.swift"),
    `// swift-tools-version:6.2

import PackageDescription

let package = Package(
  name: "SwiftPMConsumer",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(path: ${JSON.stringify(distribution)}),
  ],
  targets: [
    .target(
      name: "ViolatingFeature",
      plugins: [
        .plugin(name: "CogLintBuildToolPlugin", package: "coglintplugins"),
      ]
    ),
  ]
)
`,
  );
  return directory;
}

/** Requires a SwiftPM miss then hit with the same error and persisted replay. */
function verifySwiftPMConsumer(directory) {
  console.log("\n==> SwiftPM build-tool plugin: fresh inputs");
  const arguments_ = [
    "build",
    "--package-path",
    directory,
    "--scratch-path",
    join(directory, ".build"),
  ];
  const first = runExpectedFailure("swift", arguments_);
  const firstDiagnostics = requireDiagnostics(first, "SwiftPM fresh build");
  const cachePath = requireSingleCache(directory);
  requireHitCount(cachePath, 0, "SwiftPM fresh build");

  console.log("\n==> SwiftPM build-tool plugin: unchanged inputs");
  const second = runExpectedFailure("swift", arguments_);
  const secondDiagnostics = requireDiagnostics(second, "SwiftPM cached build");
  requireSameDiagnostics(firstDiagnostics, secondDiagnostics, "SwiftPM");
  requireHitCount(cachePath, 1, "SwiftPM cached build");
}

/** Creates a minimal macOS Xcode project with the plugin product on its target. */
function writeXcodeConsumer(distribution) {
  const directory = join(TEST_ROOT, "XcodeConsumer");
  const projectDirectory = join(directory, "XcodeConsumer.xcodeproj");
  mkdirSync(projectDirectory, { recursive: true });
  writeFileSync(join(directory, "Feature.swift"), VIOLATING_SOURCE);
  writeFileSync(join(projectDirectory, "project.pbxproj"), xcodeProject(dirname(distribution)));
  return directory;
}

/** Emits a self-contained pbxproj referencing the adjacent local distribution. */
function xcodeProject(testRoot) {
  const relativeDistribution = join("..", "CogLintPlugins");
  if (testRoot !== TEST_ROOT) {
    fail(`unexpected distribution parent: ${testRoot}`);
  }
  return `// !$*UTF8*$!
{
  archiveVersion = 1;
  classes = {};
  objectVersion = 77;
  objects = {

/* Begin PBXBuildFile section */
    A10000000000000000000001 /* Feature.swift in Sources */ = {isa = PBXBuildFile; fileRef = A10000000000000000000002 /* Feature.swift */; };
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
    A10000000000000000000002 /* Feature.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Feature.swift; sourceTree = "<group>"; };
    A10000000000000000000003 /* XcodeConsumer */ = {isa = PBXFileReference; explicitFileType = "compiled.mach-o.executable"; includeInIndex = 0; path = XcodeConsumer; sourceTree = BUILT_PRODUCTS_DIR; };
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
    A10000000000000000000004 /* Frameworks */ = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
    A10000000000000000000005 = {isa = PBXGroup; children = (A10000000000000000000002 /* Feature.swift */, A10000000000000000000006 /* Products */); sourceTree = "<group>"; };
    A10000000000000000000006 /* Products */ = {isa = PBXGroup; children = (A10000000000000000000003 /* XcodeConsumer */); name = Products; sourceTree = "<group>"; };
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
    A10000000000000000000007 /* XcodeConsumer */ = {
      isa = PBXNativeTarget;
      buildConfigurationList = A10000000000000000000008 /* Build configuration list for PBXNativeTarget "XcodeConsumer" */;
      buildPhases = (A10000000000000000000009 /* Sources */, A10000000000000000000004 /* Frameworks */);
      buildRules = ();
      dependencies = (A10000000000000000000012 /* CogLintBuildToolPlugin */);
      name = XcodeConsumer;
      packageProductDependencies = ();
      productName = XcodeConsumer;
      productReference = A10000000000000000000003 /* XcodeConsumer */;
      productType = "com.apple.product-type.tool";
    };
/* End PBXNativeTarget section */

/* Begin PBXProject section */
    A1000000000000000000000B /* Project object */ = {
      isa = PBXProject;
      attributes = {BuildIndependentTargetsInParallel = 1; LastUpgradeCheck = 2640; };
      buildConfigurationList = A1000000000000000000000C /* Build configuration list for PBXProject "XcodeConsumer" */;
      compatibilityVersion = "Xcode 15.0";
      developmentRegion = en;
      hasScannedForEncodings = 0;
      knownRegions = (en, Base);
      mainGroup = A10000000000000000000005;
      packageReferences = (A1000000000000000000000D /* XCLocalSwiftPackageReference "${relativeDistribution}" */);
      productRefGroup = A10000000000000000000006 /* Products */;
      projectDirPath = "";
      projectRoot = "";
      targets = (A10000000000000000000007 /* XcodeConsumer */);
    };
/* End PBXProject section */

/* Begin PBXSourcesBuildPhase section */
    A10000000000000000000009 /* Sources */ = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A10000000000000000000001 /* Feature.swift in Sources */); runOnlyForDeploymentPostprocessing = 0; };
/* End PBXSourcesBuildPhase section */

/* Begin PBXTargetDependency section */
    A10000000000000000000012 /* CogLintBuildToolPlugin */ = {isa = PBXTargetDependency; productRef = A1000000000000000000000A /* CogLintBuildToolPlugin */; };
/* End PBXTargetDependency section */

/* Begin XCBuildConfiguration section */
    A1000000000000000000000E /* Debug */ = {isa = XCBuildConfiguration; buildSettings = {ALWAYS_SEARCH_USER_PATHS = NO; CLANG_ENABLE_MODULES = YES; MACOSX_DEPLOYMENT_TARGET = 14.0; SDKROOT = macosx; SWIFT_VERSION = 6.0; }; name = Debug; };
    A1000000000000000000000F /* Release */ = {isa = XCBuildConfiguration; buildSettings = {ALWAYS_SEARCH_USER_PATHS = NO; CLANG_ENABLE_MODULES = YES; MACOSX_DEPLOYMENT_TARGET = 14.0; SDKROOT = macosx; SWIFT_VERSION = 6.0; }; name = Release; };
    A10000000000000000000010 /* Debug */ = {isa = XCBuildConfiguration; buildSettings = {CODE_SIGNING_ALLOWED = NO; GENERATE_INFOPLIST_FILE = YES; MACOSX_DEPLOYMENT_TARGET = 14.0; PRODUCT_BUNDLE_IDENTIFIER = dev.cog.lint.xcode-consumer; PRODUCT_NAME = "$(TARGET_NAME)"; SDKROOT = macosx; SWIFT_VERSION = 6.0; }; name = Debug; };
    A10000000000000000000011 /* Release */ = {isa = XCBuildConfiguration; buildSettings = {CODE_SIGNING_ALLOWED = NO; GENERATE_INFOPLIST_FILE = YES; MACOSX_DEPLOYMENT_TARGET = 14.0; PRODUCT_BUNDLE_IDENTIFIER = dev.cog.lint.xcode-consumer; PRODUCT_NAME = "$(TARGET_NAME)"; SDKROOT = macosx; SWIFT_VERSION = 6.0; }; name = Release; };
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
    A10000000000000000000008 /* Build configuration list for PBXNativeTarget "XcodeConsumer" */ = {isa = XCConfigurationList; buildConfigurations = (A10000000000000000000010 /* Debug */, A10000000000000000000011 /* Release */); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
    A1000000000000000000000C /* Build configuration list for PBXProject "XcodeConsumer" */ = {isa = XCConfigurationList; buildConfigurations = (A1000000000000000000000E /* Debug */, A1000000000000000000000F /* Release */); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
/* End XCConfigurationList section */

/* Begin XCLocalSwiftPackageReference section */
    A1000000000000000000000D /* XCLocalSwiftPackageReference "${relativeDistribution}" */ = {isa = XCLocalSwiftPackageReference; relativePath = ${relativeDistribution}; };
/* End XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
    A1000000000000000000000A /* CogLintBuildToolPlugin */ = {isa = XCSwiftPackageProductDependency; package = A1000000000000000000000D /* XCLocalSwiftPackageReference "${relativeDistribution}" */; productName = "plugin:CogLintBuildToolPlugin"; };
/* End XCSwiftPackageProductDependency section */
  };
  rootObject = A1000000000000000000000B /* Project object */;
}
`;
}

/** Requires an Xcode miss then hit with the same error and persisted replay. */
function verifyXcodeConsumer(directory) {
  const project = join(directory, "XcodeConsumer.xcodeproj");
  const derivedData = join(directory, "DerivedData");
  const arguments_ = [
    "-project",
    project,
    "-scheme",
    "XcodeConsumer",
    "-configuration",
    "Debug",
    "-destination",
    "platform=macOS,arch=arm64",
    "-derivedDataPath",
    derivedData,
    "-skipPackagePluginValidation",
    "CODE_SIGNING_ALLOWED=NO",
    "build",
  ];

  console.log("\n==> Xcode build-tool plugin: fresh inputs");
  const first = runExpectedFailure("xcodebuild", arguments_);
  const firstDiagnostics = requireDiagnostics(first, "Xcode fresh build");
  const cachePath = requireSingleCache(derivedData);
  requireHitCount(cachePath, 0, "Xcode fresh build");

  console.log("\n==> Xcode build-tool plugin: unchanged inputs");
  const second = runExpectedFailure("xcodebuild", arguments_);
  const secondDiagnostics = requireDiagnostics(second, "Xcode cached build");
  requireSameDiagnostics(firstDiagnostics, secondDiagnostics, "Xcode");
  requireHitCount(cachePath, 1, "Xcode cached build");
}

/** Runs a build that must fail specifically because CogLint emitted its error. */
function runExpectedFailure(command, arguments_) {
  const result = spawnSync(command, arguments_, {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (result.error !== undefined) {
    fail(`could not run ${command}: ${result.error.message}`);
  }
  if (result.signal !== null && result.signal !== undefined) {
    fail(`${command} was killed by ${result.signal}`);
  }
  const output = `${result.stdout}\n${result.stderr}`;
  process.stdout.write(output);
  if (result.status === 0) {
    fail(`${command} unexpectedly accepted the violating source`);
  }
  return output;
}

/** Extracts the exact CogLint diagnostic lines and rejects unrelated failures. */
function requireDiagnostics(output, label) {
  const diagnostics = output.split(/\r?\n/).filter((line) => line.includes(DIAGNOSTIC_FRAGMENT));
  if (diagnostics.length === 0) {
    fail(`${label} did not emit the expected CogLint diagnostic`);
  }
  return [...new Set(diagnostics)].sort();
}

/** Requires byte-identical diagnostic lines across fresh and cached builds. */
function requireSameDiagnostics(first, second, consumer) {
  if (JSON.stringify(first) !== JSON.stringify(second)) {
    fail(`${consumer} cached diagnostics differ from its fresh diagnostics`);
  }
}

/** Finds the one target-specific cache record written below a consumer root. */
function requireSingleCache(root) {
  const matches = findNamedFiles(root, "coglint-cache-v1.json");
  if (matches.length !== 1) {
    fail(`expected one CogLint cache below ${root}, found ${matches.length}`);
  }
  return matches[0];
}

/** Recursively finds regular files with one exact basename. */
function findNamedFiles(root, name) {
  if (!existsSync(root)) return [];
  const status = statSync(root);
  if (!status.isDirectory()) return root.endsWith(`/${name}`) ? [root] : [];
  return readdirSync(root).flatMap((entry) => findNamedFiles(join(root, entry), name));
}

/** Requires the cache record to prove the expected number of replays. */
function requireHitCount(cachePath, expected, label) {
  const record = JSON.parse(readFileSync(cachePath, "utf8"));
  if (record.hitCount !== expected) {
    fail(`${label} cache hitCount is ${record.hitCount}, expected ${expected}`);
  }
  console.log(`==> ${label} cache hitCount: ${record.hitCount}`);
}

/** Reports an integration failure with no false green from an expected build error. */
function fail(message) {
  console.error(`error: coglint build-tool plugin test: ${message}`);
  process.exit(1);
}
