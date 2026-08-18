// The workflow-contract checks.
//
// Each check is a named function over one `Workflow` from `model.mjs` and
// returns diagnostics. `WORKFLOW_CHECKS` is the ordered registry the CLI runs;
// later hardening slices append to it rather than editing existing checks.

import { entries, get, items, text } from "./yaml.mjs";

// ---------------------------------------------------------------------------
// POLICY CONSTANTS — the knobs this checker enforces. Edit here, nowhere else.
// ---------------------------------------------------------------------------

/** The repository the same-repo guard must name (plan.md, "CI runners"). */
const REPOSITORY = "skeswa/cog";

/**
 * Runner labels that mean "self-hosted" outright.
 *
 * `M0-05a` settled the Mac mini's repo-specific label as `cog-mini`. Add any
 * future runner label here — that is the whole update. Nothing else has to
 * change, because unknown labels already fail closed: see
 * `HOSTED_RUNNER_IMAGE`.
 */
const SELF_HOSTED_LABELS = ["self-hosted", "cog-mini"];

/**
 * Labels that name a GitHub-hosted runner image. Anything else — a bare
 * architecture label, a runner group, an unrecognized name, or a `${{ … }}`
 * expression — is treated as self-hosted, so a new label added to a workflow
 * can never silently skip the same-repo guard.
 */
const HOSTED_RUNNER_IMAGE = /^(ubuntu|macos|windows)-[\w.-]+$/i;

/** Permission values that are not a write grant. */
const READ_ONLY_PERMISSIONS = new Set(["read", "none"]);

/**
 * The only jobs allowed a write scope, and exactly which scopes.
 *
 * GitHub Pages deployment cannot be done with a read-only token: `deploy-pages`
 * needs `pages: write` to publish and `id-token: write` for the OIDC exchange
 * that proves the deployment came from this workflow. Rather than drop the
 * least-privilege check to accommodate it, the exception is written here, at
 * the exact scope, so review sees a named grant instead of a weakened rule —
 * which is the whole reason this checker exists.
 *
 * Two conditions still hold for an exception, enforced below: the extra scope
 * must appear in this table verbatim, and the job must run on a GitHub-hosted
 * runner, so a write-scoped token never reaches the persistent Mac mini.
 *
 * Keyed by workflow file name, which is unique within `.github/workflows` and
 * lets the fixtures exercise the same table the real workflows use.
 */
const PERMISSION_EXCEPTIONS = new Map([
  [
    "swift-docs.yml",
    new Map([
      [
        "deploy",
        new Map([
          ["pages", "write"],
          ["id-token", "write"],
        ]),
      ],
    ]),
  ],
]);

/** The action whose checkout token must not be left on disk. */
const CHECKOUT_ACTION = "actions/checkout";

/** A full-length, lowercase commit SHA. */
const FULL_SHA = /^[0-9a-f]{40}$/;

/** An image digest, the only pinnable form of a `docker://` reference. */
const IMAGE_DIGEST = /@sha256:[0-9a-f]{64}$/;

/** Inputs whose changes can alter the CogLint dogfood result or its execution. */
const COGLINT_TRIGGER_PATHS = [
  "Package.swift",
  "Package.resolved",
  "swift/**",
  "mise.toml",
  "tools/**",
  ".github/workflows/swift-ci.yml",
];

/** The two concrete runner lanes permitted to execute repository Swift. */
const COGLINT_SELF_HOSTED_LABELS = ["self-hosted", "macOS", "ARM64", "cog-mini"];
const COGLINT_FORK_RUNNER = "macos-26";
const COGLINT_ARTIFACT_INTEL_RUNNER = "macos-15-intel";

/** The routing predicates that keep same-repo and fork code in separate lanes. */
const COGLINT_SELF_HOSTED_CONDITION =
  "github.repository == 'skeswa/cog' && (github.event_name != 'pull_request' || " +
  "github.event.pull_request.head.repo.full_name == github.repository)";
const COGLINT_FORK_CONDITION =
  "github.event_name == 'pull_request' && " +
  "github.event.pull_request.head.repo.full_name != github.repository";
const COGLINT_ARTIFACT_CONDITION =
  "github.repository == 'skeswa/cog' && github.event_name == 'workflow_dispatch' && " +
  "(github.event_name != 'pull_request' || " +
  "github.event.pull_request.head.repo.full_name == github.repository)";

/** Files retained together as one versioned CogLint candidate. */
const COGLINT_CANDIDATE_FILES = [
  "swift/Lint/Artifacts/CogLintBinary.artifactbundle.zip",
  "swift/Lint/Artifacts/CogLintBinary.artifactbundle.zip.checksum",
  "swift/Lint/Artifacts/CogLintBinary.artifactbundle.zip.provenance",
];

// ---------------------------------------------------------------------------
// Checks
// ---------------------------------------------------------------------------

/**
 * @typedef {{path: string, line: number, check: string, message: string, job?: string}} Diagnostic
 */

/**
 * Every job on a self-hosted runner carries the same-repo guard.
 *
 * The plan's fork-security layers put a structural guard in front of the Mac
 * mini: `github.repository == 'skeswa/cog'`, plus — for workflows a fork can
 * trigger through `pull_request` — a check that the pull request's head
 * repository is this one. A guard that only holds on one side of a top-level
 * `||` is no guard, so each disjunct has to carry it.
 *
 * @param {import("./model.mjs").Workflow} workflow
 * @returns {Diagnostic[]}
 */
function selfHostedGuard(workflow) {
  /** @type {Diagnostic[]} */
  const diagnostics = [];
  const forkTriggered = workflow.triggers.some(
    (trigger) => trigger.name === "pull_request" || trigger.name === "pull_request_target",
  );

  for (const job of workflow.jobs) {
    // A job that calls a reusable workflow names no runner of its own; the
    // called workflow's jobs are checked when that file is checked.
    if (job.reusable !== null && job.runsOn.shape === "missing") continue;

    const verdict = classifyRunner(job.runsOn);
    if (!verdict.selfHosted) continue;

    const condition = job.condition;
    if (condition === null || condition.trim().length === 0) {
      diagnostics.push({
        path: workflow.path,
        line: job.line,
        check: "self-hosted-guard",
        job: job.id,
        message:
          `job \`${job.id}\` runs on ${verdict.reason}; it has no \`if:\` guard. ` +
          `Require \`github.repository == '${REPOSITORY}'\`` +
          (forkTriggered
            ? " and `github.event.pull_request.head.repo.full_name == github.repository`"
            : ""),
      });
      continue;
    }

    const disjuncts = splitTopLevel(normalizeExpression(condition), "||");
    /** @type {string[]} */
    const missing = [];
    if (!disjuncts.every((part) => hasRepositoryClause(part))) {
      missing.push(`github.repository == '${REPOSITORY}'`);
    }
    if (forkTriggered && !disjuncts.every((part) => hasHeadRepositoryClause(part))) {
      missing.push("github.event.pull_request.head.repo.full_name == github.repository");
    }
    if (missing.length === 0) continue;

    diagnostics.push({
      path: workflow.path,
      line: job.conditionLine,
      check: "self-hosted-guard",
      job: job.id,
      message:
        `job \`${job.id}\` runs on ${verdict.reason}; its \`if:\` guard is missing ` +
        `${missing.map((clause) => `\`${clause}\``).join(" and ")}` +
        (disjuncts.length > 1 ? " on every branch of its top-level `||`" : ""),
    });
  }

  return diagnostics;
}

/**
 * Every job has an effective `permissions:` block no broader than
 * `contents: read`.
 *
 * The repository default is already read-only (`M0-14`), but the plan wants
 * the grant written down where the job is read, so a missing block is an
 * error rather than an inherited default.
 *
 * The single exception is Pages deployment; see `PERMISSION_EXCEPTIONS`. It
 * applies to a job's own block only. A workflow-level write grant would hand
 * the scope to every job in the file, including one added later, so it stays
 * an error however the job is named.
 *
 * @param {import("./model.mjs").Workflow} workflow
 * @returns {Diagnostic[]}
 */
function leastPrivilegePermissions(workflow) {
  /** @type {Diagnostic[]} */
  const diagnostics = [];

  const workflowBlock = workflow.permissions;
  const hasWorkflowBlock = workflowBlock !== null && workflowBlock !== undefined;
  if (hasWorkflowBlock) {
    for (const problem of gradePermissions(workflowBlock, workflow.permissionsLine)) {
      diagnostics.push({
        path: workflow.path,
        line: problem.line,
        check: "least-privilege-permissions",
        message: `workflow-level \`permissions:\` ${problem.message}`,
      });
    }
  }

  for (const job of workflow.jobs) {
    const own = job.permissions;
    if (own === null || own === undefined) {
      if (hasWorkflowBlock) continue;
      diagnostics.push({
        path: workflow.path,
        line: job.line,
        check: "least-privilege-permissions",
        job: job.id,
        message:
          `job \`${job.id}\` has no effective \`permissions:\` block; ` +
          "add one to the job or to the workflow (`contents: read`)",
      });
      continue;
    }
    const allowed = permissionExceptionFor(workflow, job);
    for (const problem of gradePermissions(own, job.permissionsLine, allowed)) {
      diagnostics.push({
        path: workflow.path,
        line: problem.line,
        check: "least-privilege-permissions",
        job: job.id,
        message: `job \`${job.id}\` \`permissions:\` ${problem.message}`,
      });
    }
  }

  return diagnostics;
}

/**
 * No workflow uses the `pull_request_target` trigger.
 *
 * This reads the parsed `on:` key, never the file text: a comment or a job
 * name that mentions the trigger is not a use of it, and a substring scan that
 * says otherwise trains people to reword their comments.
 *
 * @param {import("./model.mjs").Workflow} workflow
 * @returns {Diagnostic[]}
 */
function noPullRequestTarget(workflow) {
  return workflow.triggers
    .filter((trigger) => trigger.name === "pull_request_target")
    .map((trigger) => ({
      path: workflow.path,
      line: trigger.line,
      check: "no-pull-request-target",
      message:
        "`pull_request_target` runs fork code against the base repository's " +
        "secrets and write-scoped token; use `pull_request`",
    }));
}

/**
 * Every checkout leaves no credentials behind.
 *
 * `actions/checkout` writes the job token into `.git/config` by default. On a
 * persistent self-hosted runner that token outlives the job unless the
 * checkout opts out.
 *
 * @param {import("./model.mjs").Workflow} workflow
 * @returns {Diagnostic[]}
 */
function credentialHygiene(workflow) {
  /** @type {Diagnostic[]} */
  const diagnostics = [];

  for (const job of workflow.jobs) {
    for (const step of job.steps) {
      if (step.uses === null) continue;
      if (actionName(step.uses).toLowerCase() !== CHECKOUT_ACTION) continue;

      const entry = entries(step.with).find((item) => item.key === "persist-credentials");
      if (entry === undefined) {
        diagnostics.push({
          path: workflow.path,
          line: step.usesLine,
          check: "credential-hygiene",
          job: job.id,
          message:
            `job \`${job.id}\` step ${step.index + 1} checks out without ` +
            "`persist-credentials: false`",
        });
        continue;
      }
      // `with:` values reach the action as strings, so `false` and `"false"`
      // are the same instruction and both are accepted.
      const value = entry.value;
      const literal = value !== null && value !== undefined && value.kind === "scalar";
      if (literal && /** @type {any} */ (value).text.trim() === "false") continue;
      diagnostics.push({
        path: workflow.path,
        line: entry.line,
        check: "credential-hygiene",
        job: job.id,
        message:
          `job \`${job.id}\` step ${step.index + 1} sets \`persist-credentials: ` +
          `${literal ? /** @type {any} */ (value).text : "…"}\`; it must be \`false\``,
      });
    }
  }

  return diagnostics;
}

/**
 * Every job bounds its own runtime.
 *
 * A hung job on a shared self-hosted runner blocks every later job on that
 * machine until the six-hour platform default expires.
 *
 * @param {import("./model.mjs").Workflow} workflow
 * @returns {Diagnostic[]}
 */
function jobTimeout(workflow) {
  /** @type {Diagnostic[]} */
  const diagnostics = [];

  for (const job of workflow.jobs) {
    // GitHub rejects `timeout-minutes` on a job that calls a reusable
    // workflow; the timeout belongs to the called workflow's own jobs.
    if (job.reusable !== null) continue;

    const value = job.timeout;
    if (value === null || value === undefined) {
      diagnostics.push({
        path: workflow.path,
        line: job.line,
        check: "job-timeout",
        job: job.id,
        message: `job \`${job.id}\` sets no \`timeout-minutes\``,
      });
      continue;
    }
    const minutes = value.kind === "scalar" ? value.value : null;
    if (typeof minutes === "number" && minutes > 0) continue;
    diagnostics.push({
      path: workflow.path,
      line: job.timeoutLine,
      check: "job-timeout",
      job: job.id,
      message:
        `job \`${job.id}\` sets \`timeout-minutes: ` +
        `${value.kind === "scalar" ? value.text : "…"}\`; it must be a positive number`,
    });
  }

  return diagnostics;
}

/**
 * Every action is pinned to a full-length commit SHA.
 *
 * A tag or branch reference is mutable, so an upstream compromise reaches this
 * repository's runners without a commit here. Repository settings already
 * require SHA pins (`M0-14`); this check keeps the requirement visible in the
 * files themselves and catches a workflow before it is pushed.
 *
 * @param {import("./model.mjs").Workflow} workflow
 * @returns {Diagnostic[]}
 */
function shaPinnedActions(workflow) {
  /** @type {Diagnostic[]} */
  const diagnostics = [];

  /**
   * @param {string} uses
   * @param {number} line
   * @param {string} what
   * @param {string} job
   */
  const inspect = (uses, line, what, job) => {
    const reference = uses.trim();
    if (reference.length === 0) return;

    // A local action or an in-repo reusable workflow travels with this commit.
    if (reference.startsWith("./") || reference.startsWith(".github/")) return;

    if (reference.startsWith("docker://")) {
      if (IMAGE_DIGEST.test(reference)) return;
      diagnostics.push({
        path: workflow.path,
        line,
        check: "sha-pinned-actions",
        job,
        message:
          `${what} uses \`${reference}\`; a \`docker://\` reference must be ` +
          "pinned by digest (`@sha256:…`)",
      });
      return;
    }

    const at = reference.lastIndexOf("@");
    if (at < 0) {
      diagnostics.push({
        path: workflow.path,
        line,
        check: "sha-pinned-actions",
        job,
        message: `${what} uses \`${reference}\` with no \`@\` reference; pin it to a commit SHA`,
      });
      return;
    }

    const actionReference = reference.slice(at + 1);
    if (FULL_SHA.test(actionReference)) return;
    const detail = /^[0-9a-fA-F]{40}$/.test(actionReference)
      ? "a commit SHA must be lowercase"
      : /^[0-9a-f]{7,39}$/.test(actionReference)
        ? "a short SHA is not a pin; use all 40 characters"
        : "tags and branches are mutable; pin to a full-length commit SHA";
    diagnostics.push({
      path: workflow.path,
      line,
      check: "sha-pinned-actions",
      job,
      message: `${what} uses \`${reference}\`: ${detail}`,
    });
  };

  for (const job of workflow.jobs) {
    if (job.reusable !== null) {
      inspect(job.reusable, job.reusableLine, `job \`${job.id}\``, job.id);
    }
    for (const step of job.steps) {
      if (step.uses === null) continue;
      inspect(step.uses, step.usesLine, `job \`${job.id}\` step ${step.index + 1}`, job.id);
    }
  }

  return diagnostics;
}

/**
 * The Swift workflow always runs CogLint over same-repo and fork changes.
 *
 * The generic checks above grade every job's hardening. This contract is more
 * specific: it keeps the dogfood command attached to both halves of the fixed
 * macOS topology, requires an explicit read-only token at each lint job, and
 * prevents a source or tool change from bypassing lint through `on.paths`.
 * It intentionally applies only to `swift-ci.yml`; fixtures use that basename
 * so they exercise the same route as the repository workflow.
 *
 * @param {import("./model.mjs").Workflow} workflow
 * @returns {Diagnostic[]}
 */
function cogLintCiContract(workflow) {
  if ((workflow.path.split("/").pop() ?? workflow.path) !== "swift-ci.yml") return [];

  /** @type {Diagnostic[]} */
  const diagnostics = [];
  for (const triggerName of ["pull_request", "push"]) {
    const trigger = workflow.triggers.find((candidate) => candidate.name === triggerName);
    if (trigger === undefined) {
      diagnostics.push({
        path: workflow.path,
        line: 1,
        check: "coglint-ci-contract",
        message: `CogLint needs the \`${triggerName}\` trigger`,
      });
      continue;
    }

    const pathsEntry = entries(trigger.configuration).find((entry) => entry.key === "paths");
    const configuredPaths = new Set(
      items(pathsEntry?.value)
        .map((item) => text(item))
        .filter((path) => path !== null && path !== undefined),
    );
    const missing = COGLINT_TRIGGER_PATHS.filter((path) => !configuredPaths.has(path));
    if (missing.length === 0) continue;
    diagnostics.push({
      path: workflow.path,
      line: pathsEntry?.line ?? trigger.line,
      check: "coglint-ci-contract",
      message:
        `\`${triggerName}.paths\` can bypass CogLint; add ` +
        missing.map((path) => `\`${path}\``).join(", "),
    });
  }

  inspectCogLintJob({
    workflow,
    diagnostics,
    id: "lint-swift",
    runnerShape: "sequence",
    runnerLabels: COGLINT_SELF_HOSTED_LABELS,
    condition: COGLINT_SELF_HOSTED_CONDITION,
  });
  inspectCogLintJob({
    workflow,
    diagnostics,
    id: "fork-lint-swift",
    runnerShape: "string",
    runnerLabels: [COGLINT_FORK_RUNNER],
    condition: COGLINT_FORK_CONDITION,
  });
  return diagnostics;
}

/**
 * @param {object} input
 * @param {import("./model.mjs").Workflow} input.workflow
 * @param {Diagnostic[]} input.diagnostics
 * @param {string} input.id
 * @param {"string" | "sequence"} input.runnerShape
 * @param {string[]} input.runnerLabels
 * @param {string} input.condition
 */
function inspectCogLintJob({ workflow, diagnostics, id, runnerShape, runnerLabels, condition }) {
  const job = workflow.jobs.find((candidate) => candidate.id === id);
  if (job === undefined) {
    diagnostics.push({
      path: workflow.path,
      line: 1,
      check: "coglint-ci-contract",
      job: id,
      message: `missing required CogLint job \`${id}\``,
    });
    return;
  }

  const actualLabels = job.runsOn.labels.map((label) => label.value);
  if (
    job.runsOn.shape !== runnerShape ||
    actualLabels.length !== runnerLabels.length ||
    !actualLabels.every((label, index) => label === runnerLabels[index])
  ) {
    const expected = runnerShape === "sequence" ? `[${runnerLabels.join(", ")}]` : runnerLabels[0];
    diagnostics.push({
      path: workflow.path,
      line: job.runsOn.line,
      check: "coglint-ci-contract",
      job: id,
      message: `job \`${id}\` must run on exactly \`${expected}\``,
    });
  }

  if (normalizeExpression(job.condition ?? "") !== normalizeExpression(condition)) {
    diagnostics.push({
      path: workflow.path,
      line: job.conditionLine,
      check: "coglint-ci-contract",
      job: id,
      message: `job \`${id}\` does not carry its exact runner-lane \`if:\` policy`,
    });
  }

  if (!hasExactContentsRead(job.permissions)) {
    diagnostics.push({
      path: workflow.path,
      line: job.permissionsLine,
      check: "coglint-ci-contract",
      job: id,
      message: `job \`${id}\` needs its own exact \`permissions: {contents: read}\` block`,
    });
  }

  if (!job.steps.some((step) => step.run?.trim() === "mise run lint:swift")) {
    diagnostics.push({
      path: workflow.path,
      line: job.line,
      check: "coglint-ci-contract",
      job: id,
      message: `job \`${id}\` must execute exactly \`mise run lint:swift\``,
    });
  }
}

/**
 * The release artifact is built only by an exact-source manual dispatch.
 *
 * Keeping this separate from ordinary PR dogfood prevents every synchronization
 * from paying for two native release builds. The manual run still follows the
 * fixed self-hosted topology, and the uploaded unit must contain the archive,
 * its independently checked checksum, and source/toolchain provenance. A
 * dependent real-Intel host must then download those bytes and exercise the
 * x86_64 member: Xcode 26.6's arm64-only SwiftPM driver cannot do that under
 * Rosetta on the build host.
 *
 * @param {import("./model.mjs").Workflow} workflow
 * @returns {Diagnostic[]}
 */
function cogLintArtifactCiContract(workflow) {
  if ((workflow.path.split("/").pop() ?? workflow.path) !== "swift-ci.yml") return [];

  /** @type {Diagnostic[]} */
  const diagnostics = [];
  if (!workflow.triggers.some((trigger) => trigger.name === "workflow_dispatch")) {
    diagnostics.push({
      path: workflow.path,
      line: 1,
      check: "coglint-artifact-ci-contract",
      message: "the exact-source CogLint candidate needs a `workflow_dispatch` trigger",
    });
  }

  const job = workflow.jobs.find((candidate) => candidate.id === "lint-artifact");
  if (job === undefined) {
    diagnostics.push({
      path: workflow.path,
      line: 1,
      check: "coglint-artifact-ci-contract",
      job: "lint-artifact",
      message: "missing required CogLint candidate job `lint-artifact`",
    });
    return diagnostics;
  }

  const actualLabels = job.runsOn.labels.map((label) => label.value);
  if (
    job.runsOn.shape !== "sequence" ||
    actualLabels.length !== COGLINT_SELF_HOSTED_LABELS.length ||
    !actualLabels.every((label, index) => label === COGLINT_SELF_HOSTED_LABELS[index])
  ) {
    diagnostics.push({
      path: workflow.path,
      line: job.runsOn.line,
      check: "coglint-artifact-ci-contract",
      job: job.id,
      message:
        "job `lint-artifact` must run on exactly " +
        `\`[${COGLINT_SELF_HOSTED_LABELS.join(", ")}]\``,
    });
  }

  if (
    normalizeExpression(job.condition ?? "") !== normalizeExpression(COGLINT_ARTIFACT_CONDITION)
  ) {
    diagnostics.push({
      path: workflow.path,
      line: job.conditionLine,
      check: "coglint-artifact-ci-contract",
      job: job.id,
      message: "job `lint-artifact` must be limited to same-repository `workflow_dispatch`",
    });
  }

  if (!hasExactContentsRead(job.permissions)) {
    diagnostics.push({
      path: workflow.path,
      line: job.permissionsLine,
      check: "coglint-artifact-ci-contract",
      job: job.id,
      message: "job `lint-artifact` needs its own exact `permissions: {contents: read}` block",
    });
  }

  const checkout = job.steps.find(
    (step) => step.uses !== null && actionName(step.uses).toLowerCase() === CHECKOUT_ACTION,
  );
  if (checkout === undefined || text(get(checkout.with, "ref")) !== "${{ github.sha }}") {
    diagnostics.push({
      path: workflow.path,
      line: checkout?.line ?? job.line,
      check: "coglint-artifact-ci-contract",
      job: job.id,
      message: "job `lint-artifact` checkout must set `ref: ${{ github.sha }}`",
    });
  }

  if (
    !job.steps.some((step) => step.run?.trim() === "mise run test:lint-artifact -- --host arm64")
  ) {
    diagnostics.push({
      path: workflow.path,
      line: job.line,
      check: "coglint-artifact-ci-contract",
      job: job.id,
      message:
        "job `lint-artifact` must build and probe arm64 with exactly " +
        "`mise run test:lint-artifact -- --host arm64`",
    });
  }

  const provenance = job.steps.find(
    (step) =>
      step.run?.includes("format=coglint-candidate-v1") === true &&
      step.run.includes("swift package compute-checksum") &&
      step.run.includes("$COG_XCODE_BUILD") &&
      step.run.includes("arm64_probe=passed"),
  );
  if (provenance === undefined) {
    diagnostics.push({
      path: workflow.path,
      line: job.line,
      check: "coglint-artifact-ci-contract",
      job: job.id,
      message:
        "job `lint-artifact` must verify source, Xcode build, and checksum before writing v1 provenance",
    });
  }

  const upload = job.steps.find(
    (step) =>
      step.uses !== null && actionName(step.uses).toLowerCase() === "actions/upload-artifact",
  );
  const uploadedPaths = new Set(
    (text(get(upload?.with, "path")) ?? "")
      .split(/\r?\n/)
      .map((path) => path.trim())
      .filter((path) => path.length > 0),
  );
  const uploadSettingsValid =
    upload !== undefined &&
    text(get(upload.with, "name")) === "coglint-0.4.0-${{ github.sha }}" &&
    COGLINT_CANDIDATE_FILES.every((path) => uploadedPaths.has(path)) &&
    text(get(upload.with, "if-no-files-found")) === "error" &&
    text(get(upload.with, "compression-level")) === "0";
  if (!uploadSettingsValid) {
    diagnostics.push({
      path: workflow.path,
      line: upload?.line ?? job.line,
      check: "coglint-artifact-ci-contract",
      job: job.id,
      message:
        "job `lint-artifact` must upload the SHA-named archive, checksum, and provenance without recompression",
    });
  }

  const intelJob = workflow.jobs.find((candidate) => candidate.id === "lint-artifact-x86_64");
  if (intelJob === undefined) {
    diagnostics.push({
      path: workflow.path,
      line: 1,
      check: "coglint-artifact-ci-contract",
      job: "lint-artifact-x86_64",
      message: "missing required downloaded-artifact proof job `lint-artifact-x86_64`",
    });
    return diagnostics;
  }

  if (
    intelJob.runsOn.shape !== "string" ||
    intelJob.runsOn.labels.length !== 1 ||
    intelJob.runsOn.labels[0].value !== COGLINT_ARTIFACT_INTEL_RUNNER
  ) {
    diagnostics.push({
      path: workflow.path,
      line: intelJob.runsOn.line,
      check: "coglint-artifact-ci-contract",
      job: intelJob.id,
      message: `job \`lint-artifact-x86_64\` must run on \`${COGLINT_ARTIFACT_INTEL_RUNNER}\``,
    });
  }

  if (text(intelJob.needs) !== "lint-artifact") {
    diagnostics.push({
      path: workflow.path,
      line: intelJob.needsLine,
      check: "coglint-artifact-ci-contract",
      job: intelJob.id,
      message: "job `lint-artifact-x86_64` must depend directly on `lint-artifact`",
    });
  }

  if (
    normalizeExpression(intelJob.condition ?? "") !==
    normalizeExpression(COGLINT_ARTIFACT_CONDITION)
  ) {
    diagnostics.push({
      path: workflow.path,
      line: intelJob.conditionLine,
      check: "coglint-artifact-ci-contract",
      job: intelJob.id,
      message: "job `lint-artifact-x86_64` must be limited to same-repository `workflow_dispatch`",
    });
  }

  if (!hasExactContentsRead(intelJob.permissions)) {
    diagnostics.push({
      path: workflow.path,
      line: intelJob.permissionsLine,
      check: "coglint-artifact-ci-contract",
      job: intelJob.id,
      message:
        "job `lint-artifact-x86_64` needs its own exact `permissions: {contents: read}` block",
    });
  }

  const intelCheckout = intelJob.steps.find(
    (step) => step.uses !== null && actionName(step.uses).toLowerCase() === CHECKOUT_ACTION,
  );
  if (intelCheckout === undefined || text(get(intelCheckout.with, "ref")) !== "${{ github.sha }}") {
    diagnostics.push({
      path: workflow.path,
      line: intelCheckout?.line ?? intelJob.line,
      check: "coglint-artifact-ci-contract",
      job: intelJob.id,
      message: "job `lint-artifact-x86_64` checkout must set `ref: ${{ github.sha }}`",
    });
  }

  const intelToolchain = intelJob.steps.find(
    (step) =>
      step.run?.includes("COG_INTEL_XCODE_VERSION") === true &&
      step.run.includes("COG_INTEL_XCODE_BUILD") &&
      step.run.includes("DEVELOPER_DIR") &&
      step.run.includes("xcodebuild -version") &&
      step.run.includes("swift --version"),
  );
  if (intelToolchain === undefined) {
    diagnostics.push({
      path: workflow.path,
      line: intelJob.line,
      check: "coglint-artifact-ci-contract",
      job: intelJob.id,
      message:
        "job `lint-artifact-x86_64` must select and record its pinned Intel Xcode version and build",
    });
  }

  const download = intelJob.steps.find(
    (step) =>
      step.uses !== null && actionName(step.uses).toLowerCase() === "actions/download-artifact",
  );
  if (
    download === undefined ||
    text(get(download.with, "name")) !== "coglint-0.4.0-${{ github.sha }}" ||
    text(get(download.with, "path")) !== "swift/Lint/Artifacts"
  ) {
    diagnostics.push({
      path: workflow.path,
      line: download?.line ?? intelJob.line,
      check: "coglint-artifact-ci-contract",
      job: intelJob.id,
      message:
        "job `lint-artifact-x86_64` must download the SHA-named candidate into `swift/Lint/Artifacts`",
    });
  }

  const downloadedProof = intelJob.steps.find(
    (step) =>
      step.run?.includes("$(uname -m)") === true &&
      step.run.includes("GITHUB_SHA") &&
      step.run.includes("swift package compute-checksum") &&
      step.run.includes("arm64_probe=passed"),
  );
  if (downloadedProof === undefined) {
    diagnostics.push({
      path: workflow.path,
      line: intelJob.line,
      check: "coglint-artifact-ci-contract",
      job: intelJob.id,
      message:
        "job `lint-artifact-x86_64` must verify its Intel host and the downloaded source, checksum, and arm64 proof",
    });
  }

  if (
    !intelJob.steps.some(
      (step) => step.run?.trim() === "mise run test:lint-artifact -- --from-archive --host x86_64",
    )
  ) {
    diagnostics.push({
      path: workflow.path,
      line: intelJob.line,
      check: "coglint-artifact-ci-contract",
      job: intelJob.id,
      message:
        "job `lint-artifact-x86_64` must probe the downloaded archive with exactly " +
        "`mise run test:lint-artifact -- --from-archive --host x86_64`",
    });
  }

  return diagnostics;
}

/** @param {import("./yaml.mjs").Node | null | undefined} permissions */
function hasExactContentsRead(permissions) {
  const permissionEntries = entries(permissions);
  return (
    permissionEntries.length === 1 &&
    permissionEntries[0].key === "contents" &&
    text(permissionEntries[0].value) === "read"
  );
}

/** The ordered registry the CLI runs. */
export const WORKFLOW_CHECKS = [
  { name: "no-pull-request-target", run: noPullRequestTarget },
  { name: "self-hosted-guard", run: selfHostedGuard },
  { name: "least-privilege-permissions", run: leastPrivilegePermissions },
  { name: "credential-hygiene", run: credentialHygiene },
  { name: "job-timeout", run: jobTimeout },
  { name: "sha-pinned-actions", run: shaPinnedActions },
  { name: "coglint-ci-contract", run: cogLintCiContract },
  { name: "coglint-artifact-ci-contract", run: cogLintArtifactCiContract },
];

/**
 * Runs every check over every workflow.
 *
 * @param {import("./model.mjs").Workflow[]} workflows
 */
export function runChecks(workflows) {
  /** @type {Diagnostic[]} */
  const diagnostics = [];
  for (const workflow of workflows) {
    for (const check of WORKFLOW_CHECKS) diagnostics.push(...check.run(workflow));
  }
  return { diagnostics, checkNames: WORKFLOW_CHECKS.map((check) => check.name) };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Decides whether a job's runner is self-hosted, failing closed on anything
 * that is not recognizably a GitHub-hosted image.
 *
 * @param {import("./model.mjs").RunsOn} runsOn
 * @returns {{selfHosted: boolean, reason: string}}
 */
export function classifyRunner(runsOn) {
  if (runsOn.shape === "missing") {
    return { selfHosted: true, reason: "no declared `runs-on:` runner" };
  }
  if (runsOn.labels.length === 0) {
    return { selfHosted: true, reason: "a runner group with no labels" };
  }

  const explicit = runsOn.labels.find((label) =>
    SELF_HOSTED_LABELS.includes(label.value.toLowerCase()),
  );
  if (explicit !== undefined) {
    return { selfHosted: true, reason: `the \`${explicit.value}\` runner` };
  }

  const unknown = runsOn.labels.find((label) => !HOSTED_RUNNER_IMAGE.test(label.value));
  if (unknown !== undefined) {
    return {
      selfHosted: true,
      reason: unknown.value.includes("${{")
        ? `a computed label (\`${unknown.value}\`), which cannot be proven hosted`
        : `the \`${unknown.value}\` label, which is not a GitHub-hosted runner image`,
    };
  }

  return { selfHosted: false, reason: "a GitHub-hosted runner" };
}

/**
 * Normalizes an `if:` expression for clause matching: `${{ … }}` wrappers
 * dropped, double quotes folded to single, whitespace collapsed.
 *
 * @param {string} condition
 */
function normalizeExpression(condition) {
  return condition
    .replaceAll("${{", " ")
    .replaceAll("}}", " ")
    .replaceAll('"', "'")
    .replace(/\s+/g, " ")
    .trim();
}

/**
 * Splits an expression on a top-level operator, ignoring anything nested in
 * parentheses, brackets, or quotes.
 *
 * @param {string} expression
 * @param {string} operator
 * @returns {string[]}
 */
function splitTopLevel(expression, operator) {
  /** @type {string[]} */
  const parts = [];
  let depth = 0;
  let quote = "";
  let start = 0;
  for (let index = 0; index < expression.length; index += 1) {
    const char = expression[index];
    if (quote !== "") {
      if (char === quote) quote = "";
      continue;
    }
    if (char === "'") {
      quote = char;
      continue;
    }
    if (char === "(" || char === "[") depth += 1;
    else if (char === ")" || char === "]") depth -= 1;
    else if (depth === 0 && expression.startsWith(operator, index)) {
      parts.push(expression.slice(start, index));
      index += operator.length - 1;
      start = index + 1;
    }
  }
  parts.push(expression.slice(start));
  return parts.map((part) => part.trim()).filter((part) => part.length > 0);
}

/** @param {string} expression */
function hasRepositoryClause(expression) {
  const literal = escapeRegExp(`'${REPOSITORY}'`);
  return (
    new RegExp(`github\\.repository\\s*==\\s*${literal}`).test(expression) ||
    new RegExp(`${literal}\\s*==\\s*github\\.repository`).test(expression)
  );
}

/** @param {string} expression */
function hasHeadRepositoryClause(expression) {
  const head = "github\\.event\\.pull_request\\.head\\.repo\\.full_name";
  const target = `(github\\.repository|${escapeRegExp(`'${REPOSITORY}'`)})`;
  return (
    new RegExp(`${head}\\s*==\\s*${target}`).test(expression) ||
    new RegExp(`${target}\\s*==\\s*${head}`).test(expression)
  );
}

/** @param {string} value */
function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&");
}

/**
 * Grades one `permissions:` block against "no broader than `contents: read`".
 *
 * @param {import("./yaml.mjs").Node} node
 * @param {number} line
 * @returns {{line: number, message: string}[]}
 */
function gradePermissions(node, line, allowed = null) {
  if (node.kind === "scalar") {
    const value = node.text.trim();
    if (value === "{}") return [];
    return [
      {
        line: node.line,
        message:
          `is \`${value}\`, which grants every scope; list only the scopes the ` +
          "job needs (`contents: read`)",
      },
    ];
  }

  if (node.kind !== "map") {
    return [{ line, message: "must be a mapping of scope to `read` or `none`" }];
  }

  /** @type {{line: number, message: string}[]} */
  const problems = [];
  for (const entry of node.entries) {
    const value = text(entry.value)?.trim() ?? "";
    if (READ_ONLY_PERMISSIONS.has(value)) continue;
    if (allowed?.get(entry.key) === value) continue;
    problems.push({
      line: entry.line,
      message: `grants \`${entry.key}: ${value}\`; only \`read\` or \`none\` is allowed`,
    });
  }
  return problems;
}

/**
 * The write scopes this exact job may hold, or `null` for the usual rule.
 *
 * An exception is granted only to a hosted job: the table names the scope, and
 * the runner classification keeps the resulting write-scoped token off the
 * persistent self-hosted runner. A job that matches the table by name but runs
 * somewhere else is graded like any other job, so moving it to the mini turns
 * the exception off rather than carrying it along.
 *
 * @param {import("./model.mjs").Workflow} workflow
 * @param {import("./model.mjs").Job} job
 * @returns {Map<string, string> | null}
 */
function permissionExceptionFor(workflow, job) {
  const fileName = workflow.path.split("/").pop() ?? workflow.path;
  const allowed = PERMISSION_EXCEPTIONS.get(fileName)?.get(job.id);
  if (allowed === undefined) return null;
  return classifyRunner(job.runsOn).selfHosted ? null : allowed;
}

/**
 * The `owner/repo` part of a `uses:` reference.
 *
 * @param {string} uses
 */
function actionName(uses) {
  const at = uses.lastIndexOf("@");
  return (at < 0 ? uses : uses.slice(0, at)).trim();
}
