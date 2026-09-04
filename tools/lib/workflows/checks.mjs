// The workflow-contract checks.
//
// Each check is a named function over one `Workflow` from `model.mjs` and
// returns diagnostics. `WORKFLOW_CHECKS` is the ordered registry the CLI runs;
// later hardening slices append to it rather than editing existing checks.

import { entries, get, items, text } from "./yaml.mjs";

// ---------------------------------------------------------------------------
// POLICY CONSTANTS — the knobs this checker enforces. Edit here, nowhere else.
// ---------------------------------------------------------------------------

/** The repository the same-repo guard must name (see maintainers/ci.md). */
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
    "docs.yml",
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
  [
    "release.yml",
    new Map([
      [
        "release-please",
        new Map([
          ["actions", "write"],
          ["contents", "write"],
          ["pull-requests", "write"],
          ["issues", "write"],
        ]),
      ],
      ["recover-candidate", new Map([["actions", "write"]])],
      ["publish", new Map([["contents", "write"]])],
      ["dispatch-docs", new Map([["actions", "write"]])],
    ]),
  ],
  ["publish.yml", new Map([["publish", new Map([["contents", "write"]])]])],
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

/**
 * The two concrete runner lanes permitted to execute repository Swift.
 *
 * The same-repo lane's home is the pinned Mac mini —
 * `{ shape: "sequence", labels: ["self-hosted", "macOS", "ARM64", "cog-mini"] }`
 * — but while the mini is unavailable the lane rides the hosted `macos-26`
 * image, and this constant is the policy the contract enforces, so it names
 * the hosted image for now. Restoring the mini means swapping this constant
 * back to the label sequence in the same revision as the `runs-on:` swap in
 * `swift-ci.yml` (see `docs/maintainers/ci.md`, "Temporary hosted topology").
 */
const COGLINT_SAME_REPO_RUNNER = { shape: "string", labels: ["macos-26"] };
const COGLINT_FORK_RUNNER = "macos-26";
const COGLINT_ARTIFACT_INTEL_RUNNER = "macos-15-intel";
const COGLINT_CANDIDATE_RUNNER_RECORD = "github-hosted-macos-26";

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
  "swift/Lint/Artifacts/CogLintBinary.artifactbundle.zip.provenance.json",
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
    runnerShape: COGLINT_SAME_REPO_RUNNER.shape,
    runnerLabels: COGLINT_SAME_REPO_RUNNER.labels,
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
 * fixed same-repository topology, and the uploaded unit must contain the archive,
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
  const dispatch = workflow.triggers.find((trigger) => trigger.name === "workflow_dispatch");
  if (dispatch === undefined) {
    diagnostics.push({
      path: workflow.path,
      line: 1,
      check: "coglint-artifact-ci-contract",
      message: "the exact-source CogLint candidate needs a `workflow_dispatch` trigger",
    });
  } else {
    const releasePr = get(get(dispatch.configuration, "inputs"), "release_pr");
    if (text(get(releasePr, "required")) !== "true") {
      diagnostics.push({
        path: workflow.path,
        line: dispatch.line,
        check: "coglint-artifact-ci-contract",
        message: "`workflow_dispatch` must require the Release Please PR number as `release_pr`",
      });
    }
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
    job.runsOn.shape !== COGLINT_SAME_REPO_RUNNER.shape ||
    actualLabels.length !== COGLINT_SAME_REPO_RUNNER.labels.length ||
    !actualLabels.every((label, index) => label === COGLINT_SAME_REPO_RUNNER.labels[index])
  ) {
    const expected =
      COGLINT_SAME_REPO_RUNNER.shape === "sequence"
        ? `[${COGLINT_SAME_REPO_RUNNER.labels.join(", ")}]`
        : COGLINT_SAME_REPO_RUNNER.labels[0];
    diagnostics.push({
      path: workflow.path,
      line: job.runsOn.line,
      check: "coglint-artifact-ci-contract",
      job: job.id,
      message: `job \`lint-artifact\` must run on exactly \`${expected}\``,
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

  if (!hasExactPermissions(job.permissions, { contents: "read", "pull-requests": "read" })) {
    diagnostics.push({
      path: workflow.path,
      line: job.permissionsLine,
      check: "coglint-artifact-ci-contract",
      job: job.id,
      message:
        "job `lint-artifact` needs exact read access to contents and pull requests, and nothing else",
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

  const binding = job.steps.find(
    (step) =>
      step.run?.includes("pulls/${RELEASE_PR}") === true &&
      step.run.includes('source_sha" != "$pr_head_sha') &&
      step.run.includes("GITHUB_REF_TYPE") &&
      step.run.includes("pr_head_tree") &&
      step.run.includes("source_tree"),
  );
  if (binding === undefined) {
    diagnostics.push({
      path: workflow.path,
      line: job.line,
      check: "coglint-artifact-ci-contract",
      job: job.id,
      message:
        "job `lint-artifact` must bind an ordinary dispatch to the current release PR head and recovery to an immutable tag with the same tree",
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
      step.run?.includes('format: "coglint-candidate-v2"') === true &&
      step.run.includes("swift package compute-checksum") &&
      step.run.includes("$COG_XCODE_BUILD") &&
      step.run.includes("pr_head_sha") &&
      step.run.includes("source_tree") &&
      step.run.includes('architectures: ["arm64", "x86_64"]') &&
      step.run.includes(`runner: "${COGLINT_CANDIDATE_RUNNER_RECORD}"`) &&
      step.run.includes('arm64_probe: "passed"'),
  );
  if (provenance === undefined) {
    diagnostics.push({
      path: workflow.path,
      line: job.line,
      check: "coglint-artifact-ci-contract",
      job: job.id,
      message:
        "job `lint-artifact` must record the candidate runner and verify the PR/source tree, toolchain, architectures, and checksum before writing versioned JSON provenance",
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
    text(get(upload.with, "name")) ===
      "coglint-build-${{ steps.candidate.outputs.version }}-${{ steps.candidate.outputs.pr_head_sha }}" &&
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
        "job `lint-artifact` must upload the version/PR-head-qualified build handoff, checksum, and JSON provenance without recompression",
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
    text(get(download.with, "name")) !==
      "coglint-build-${{ needs.lint-artifact.outputs.version }}-${{ needs.lint-artifact.outputs.pr_head_sha }}" ||
    text(get(download.with, "path")) !== "swift/Lint/Artifacts"
  ) {
    diagnostics.push({
      path: workflow.path,
      line: download?.line ?? intelJob.line,
      check: "coglint-artifact-ci-contract",
      job: intelJob.id,
      message:
        "job `lint-artifact-x86_64` must download the version/PR-head-qualified build handoff into `swift/Lint/Artifacts`",
    });
  }

  const downloadedProof = intelJob.steps.find(
    (step) =>
      step.run?.includes("$(uname -m)") === true &&
      step.run.includes("swift package compute-checksum") &&
      step.run.includes("coglint-candidate-v2") &&
      step.run.includes("PR_HEAD_SHA") &&
      step.run.includes("SOURCE_TREE") &&
      step.run.includes('arm64_probe == "passed"'),
  );
  if (downloadedProof === undefined) {
    diagnostics.push({
      path: workflow.path,
      line: intelJob.line,
      check: "coglint-artifact-ci-contract",
      job: intelJob.id,
      message:
        "job `lint-artifact-x86_64` must verify its Intel host and the downloaded PR/source tree, checksum, architectures, and arm64 proof",
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

  const finalUpload = intelJob.steps.find(
    (step) =>
      step.uses !== null &&
      actionName(step.uses).toLowerCase() === "actions/upload-artifact" &&
      text(get(step.with, "name")) ===
        "coglint-candidate-${{ needs.lint-artifact.outputs.version }}-${{ needs.lint-artifact.outputs.pr_head_sha }}",
  );
  const finalPaths = new Set(
    (text(get(finalUpload?.with, "path")) ?? "")
      .split(/\r?\n/)
      .map((path) => path.trim())
      .filter(Boolean),
  );
  if (
    finalUpload === undefined ||
    !COGLINT_CANDIDATE_FILES.every((path) => finalPaths.has(path)) ||
    text(get(finalUpload.with, "retention-days")) !== "90"
  ) {
    diagnostics.push({
      path: workflow.path,
      line: finalUpload?.line ?? intelJob.line,
      check: "coglint-artifact-ci-contract",
      job: intelJob.id,
      message:
        "job `lint-artifact-x86_64` must retain the publication-ready version/PR-head-qualified archive, checksum, and JSON provenance for 90 days",
    });
  }

  const gate = workflow.jobs.find((candidate) => candidate.id === "candidate-gate");
  const gateNeeds = new Set(
    items(gate?.needs)
      .map((entry) => text(entry))
      .filter(Boolean),
  );
  const completeCandidateGraph = [
    "candidate-changes",
    "format",
    "lint-swift",
    "lint-artifact-x86_64",
    "candidate-extras",
    "test-host",
    "test-simulator",
    "build-weather",
    "test-release",
    "compile-fail",
    "bench-build",
  ];
  if (
    gate === undefined ||
    gate.name !== "Release candidate" ||
    !isHostedRunner(gate, "ubuntu-latest") ||
    !hasExactContentsRead(gate.permissions) ||
    completeCandidateGraph.some((dependency) => !gateNeeds.has(dependency))
  ) {
    diagnostics.push({
      path: workflow.path,
      line: gate?.needsLine ?? gate?.line ?? 1,
      check: "coglint-artifact-ci-contract",
      job: "candidate-gate",
      message:
        "the hosted `Release candidate` gate must depend on Conventional Commits and the complete format, test, simulator, example, lint, documentation, benchmark, and native-artifact graph",
    });
  }

  return diagnostics;
}

/** Every PR and push is linted as release input, without path-based escape hatches. */
function conventionalCommitsContract(workflow) {
  if ((workflow.path.split("/").pop() ?? workflow.path) !== "conventional-commits.yml") return [];
  /** @type {Diagnostic[]} */
  const diagnostics = [];
  for (const name of ["pull_request", "push"]) {
    const trigger = workflow.triggers.find((candidate) => candidate.name === name);
    if (trigger === undefined || get(trigger.configuration, "paths") !== undefined) {
      diagnostics.push({
        path: workflow.path,
        line: trigger?.line ?? 1,
        check: "conventional-commits-contract",
        message: `Conventional Commits must run on every \`${name}\` with no path filters`,
      });
    }
  }

  const job = workflow.jobs.find((candidate) => candidate.id === "conventional-commits");
  if (job === undefined) {
    diagnostics.push({
      path: workflow.path,
      line: 1,
      check: "conventional-commits-contract",
      message: "missing required `conventional-commits` job",
    });
    return diagnostics;
  }
  if (!isHostedRunner(job, "ubuntu-latest") || !hasExactContentsRead(job.permissions)) {
    diagnostics.push({
      path: workflow.path,
      line: job.line,
      check: "conventional-commits-contract",
      job: job.id,
      message: "the Conventional Commits job must be hosted and exactly read-only",
    });
  }
  const checkout = findActionStep(job, CHECKOUT_ACTION);
  if (
    text(get(checkout?.with, "fetch-depth")) !== "0" ||
    text(get(checkout?.with, "ref")) !==
      "${{ github.event_name == 'pull_request' && github.event.pull_request.head.sha || github.sha }}"
  ) {
    diagnostics.push({
      path: workflow.path,
      line: checkout?.line ?? job.line,
      check: "conventional-commits-contract",
      job: job.id,
      message: "the check must fetch history at the authoritative PR head or push SHA",
    });
  }
  if (
    !job.steps.some((step) => step.run?.trim() === "npm ci --ignore-scripts") ||
    !job.steps.some((step) => step.run?.trim() === "mise run changes:check")
  ) {
    diagnostics.push({
      path: workflow.path,
      line: job.line,
      check: "conventional-commits-contract",
      job: job.id,
      message: "the check must install the lockfile and run exactly `mise run changes:check`",
    });
  }
  return diagnostics;
}

/** Release Please, candidate dispatch, protected publication, recovery, and the two handoffs stay narrowly separated. */
function releaseWorkflowContract(workflow) {
  if ((workflow.path.split("/").pop() ?? workflow.path) !== "release.yml") return [];
  /** @type {Diagnostic[]} */
  const diagnostics = [];
  const expected = [
    [
      "release-please",
      { actions: "write", contents: "write", "pull-requests": "write", issues: "write" },
    ],
    ["recover-candidate", { actions: "write", contents: "read" }],
    ["publish", { actions: "read", contents: "write", "pull-requests": "read" }],
    ["dispatch-docs", { actions: "write", contents: "read" }],
    ["dispatch-plugins", { contents: "read" }],
  ];
  for (const [id, permissions] of expected) {
    const job = workflow.jobs.find((candidate) => candidate.id === id);
    if (job === undefined || !isHostedRunner(job, "ubuntu-latest")) {
      diagnostics.push({
        path: workflow.path,
        line: job?.line ?? 1,
        check: "release-workflow-contract",
        job: id,
        message: `release job \`${id}\` must exist on \`ubuntu-latest\``,
      });
      continue;
    }
    if (!hasExactPermissions(job.permissions, permissions)) {
      diagnostics.push({
        path: workflow.path,
        line: job.permissionsLine,
        check: "release-workflow-contract",
        job: id,
        message: `release job \`${id}\` has drifted from its exact permission set`,
      });
    }
  }

  const releasePlease = workflow.jobs.find((job) => job.id === "release-please");
  const releaseStep = releasePlease?.steps.find(
    (step) =>
      step.uses === "googleapis/release-please-action@45996ed1f6d02564a971a2fa1b5860e934307cf7",
  );
  if (
    releasePlease === undefined ||
    releasePlease.steps.some(
      (step) => actionName(step.uses ?? "").toLowerCase() === CHECKOUT_ACTION,
    ) ||
    releaseStep === undefined ||
    text(get(releaseStep.with, "config-file")) !== "release-please-config.json" ||
    text(get(releaseStep.with, "manifest-file")) !== ".release-please-manifest.json"
  ) {
    diagnostics.push({
      path: workflow.path,
      line: releaseStep?.line ?? releasePlease?.line ?? 1,
      check: "release-workflow-contract",
      job: "release-please",
      message:
        "Release Please must use the v5.0.0 SHA and manifest configuration without checking out repository code",
    });
  }

  const releasePleaseSource = releasePlease?.steps.map((step) => step.run ?? "").join("\n") ?? "";
  if (
    !releasePleaseSource.includes(
      'gh workflow run swift-ci.yml --repo "$GITHUB_REPOSITORY" --ref "$branch"',
    ) ||
    !releasePleaseSource.includes("release_pr=${number}") ||
    !releasePleaseSource.includes("--label 'autorelease: pending'") ||
    !releasePleaseSource.includes("--jq .behind_by") ||
    !releasePleaseSource.includes("updateMethod: REBASE")
  ) {
    diagnostics.push({
      path: workflow.path,
      line: releasePlease?.line ?? 1,
      check: "release-workflow-contract",
      job: "release-please",
      message:
        "Release Please must rebase a stale open release PR and dispatch the Swift CI candidate at the proposed PR head with explicit repository context",
    });
  }

  const recovery = workflow.jobs.find((job) => job.id === "recover-candidate");
  const recoverySource = recovery?.steps.map((step) => step.run ?? "").join("\n") ?? "";
  if (
    !recoverySource.includes("object.type") ||
    !recoverySource.includes("contents/version.txt?ref=${TAG}") ||
    !recoverySource.includes('gh workflow run swift-ci.yml --repo "$GITHUB_REPOSITORY"') ||
    !recoverySource.includes("recovery_tag=${TAG}") ||
    !recoverySource.includes('gh run watch "$run_id" --repo "$GITHUB_REPOSITORY" --exit-status')
  ) {
    diagnostics.push({
      path: workflow.path,
      line: recovery?.line ?? 1,
      check: "release-workflow-contract",
      job: "recover-candidate",
      message:
        "recovery must require an immutable tag with a matching version, then dispatch and wait for tag-bound Swift CI with explicit repository context",
    });
  }

  const publish = workflow.jobs.find((job) => job.id === "publish");
  const publishSource = publish?.steps.map((step) => step.run ?? "").join("\n") ?? "";
  if (!publishSource.includes(`.build.runner == "${COGLINT_CANDIDATE_RUNNER_RECORD}"`)) {
    diagnostics.push({
      path: workflow.path,
      line: publish?.line ?? 1,
      check: "release-workflow-contract",
      job: "publish",
      message:
        `publisher must require the current candidate runner record ` +
        `\`${COGLINT_CANDIDATE_RUNNER_RECORD}\``,
    });
  }
  if (
    !publishSource.includes('gh release view "$tag" --repo "$GITHUB_REPOSITORY"') ||
    !publishSource.includes("--json isDraft,isPrerelease,targetCommitish")
  ) {
    diagnostics.push({
      path: workflow.path,
      line: publish?.line ?? 1,
      check: "release-workflow-contract",
      job: "publish",
      message: "publisher must use a draft-aware release lookup before publication",
    });
  }
  if (
    environmentName(publish) !== "cog-release" ||
    !publishSource.includes(".github/workflows/swift-ci.yml") ||
    !publishSource.includes("coglint-candidate-${version}-${pr_head_sha}") ||
    !publishSource.includes("source_tree == $source_tree") ||
    !publishSource.includes("workflow == $workflow") ||
    !publishSource.includes("workflow_run_id == $run_id") ||
    !publishSource.includes('.build.xcode_build == "17F113"') ||
    !publishSource.includes('.intel.xcode_build == "17C529"') ||
    !publishSource.includes("Release was published early") ||
    !publishSource.includes("Divergent release asset") ||
    !publishSource.includes('gh release edit "$TAG" --title "Cog ${VERSION}" --draft=false')
  ) {
    diagnostics.push({
      path: workflow.path,
      line: publish?.environmentLine ?? publish?.line ?? 1,
      check: "release-workflow-contract",
      job: "publish",
      message:
        "publisher must use `cog-release` and verify workflow identity, PR/tag tree, provenance, checksum, and existing assets before publication",
    });
  }

  const docs = workflow.jobs.find((job) => job.id === "dispatch-docs");
  if (
    docs === undefined ||
    text(docs.needs) !== "publish" ||
    !docs.steps.some(
      (step) =>
        step.run?.trim() === 'gh workflow run docs.yml --repo "$GITHUB_REPOSITORY" --ref "$TAG"',
    )
  ) {
    diagnostics.push({
      path: workflow.path,
      line: docs?.line ?? 1,
      check: "release-workflow-contract",
      job: "dispatch-docs",
      message:
        "a successful publication must explicitly dispatch `docs.yml` at the release tag and repository",
    });
  }

  const plugins = workflow.jobs.find((job) => job.id === "dispatch-plugins");
  const pluginsSource = plugins?.steps.map((step) => step.run ?? "").join("\n") ?? "";
  if (
    plugins === undefined ||
    !pluginsSource.includes(
      'gh workflow run publish.yml --repo skeswa/coglint-plugins --ref main -f "cog_version=${VERSION}"',
    ) ||
    !plugins.steps.some((step) =>
      text(get(step.env, "GH_TOKEN"))?.includes("secrets.COGLINT_PLUGINS_DISPATCH_TOKEN"),
    )
  ) {
    diagnostics.push({
      path: workflow.path,
      line: plugins?.line ?? 1,
      check: "release-workflow-contract",
      job: "dispatch-plugins",
      message:
        "a successful publication must dispatch the sibling `coglint-plugins` publication at the released version under its scoped token",
    });
  }
  return diagnostics;
}

/** The sibling keeps generation read-only and gates only a no-execution commit job. */
function cogLintPublicationContract(workflow) {
  if (
    (workflow.path.split("/").pop() ?? workflow.path) !== "publish.yml" ||
    workflow.name !== "Publish CogLintPlugins"
  ) {
    return [];
  }
  /** @type {Diagnostic[]} */
  const diagnostics = [];
  const dispatch = workflow.triggers.find((trigger) => trigger.name === "workflow_dispatch");
  const version = get(get(dispatch?.configuration, "inputs"), "cog_version");
  if (dispatch === undefined || text(get(version, "required")) !== "true") {
    diagnostics.push({
      path: workflow.path,
      line: dispatch?.line ?? 1,
      check: "coglint-publication-contract",
      message: "sibling publication must require a `cog_version` dispatch input",
    });
  }

  const prepare = workflow.jobs.find((job) => job.id === "prepare");
  const publish = workflow.jobs.find((job) => job.id === "publish");
  const consume = workflow.jobs.find((job) => job.id === "consume");
  if (
    prepare === undefined ||
    !isHostedRunner(prepare, "macos-15") ||
    !hasExactContentsRead(prepare.permissions)
  ) {
    diagnostics.push({
      path: workflow.path,
      line: prepare?.line ?? 1,
      check: "coglint-publication-contract",
      job: "prepare",
      message: "sibling preparation must run read-only on hosted macOS",
    });
  }
  const prepareSource = prepare?.steps.map((step) => step.run ?? "").join("\n") ?? "";
  if (
    !prepareSource.includes("releases/tags/${VERSION}") ||
    !prepareSource.includes("source_tree == $tree") ||
    !prepareSource.includes(".checksum == $checksum") ||
    !prepareSource.includes('.architectures == ["arm64", "x86_64"]') ||
    !prepareSource.includes('.build.arm64_probe == "passed"') ||
    !prepareSource.includes('.intel.x86_64_probe == "passed"') ||
    !prepareSource.includes("generate-coglint-plugins.mjs") ||
    !prepareSource.includes("swift build --package-path") ||
    !prepareSource.includes("sibling_main_sha")
  ) {
    diagnostics.push({
      path: workflow.path,
      line: prepare?.line ?? 1,
      check: "coglint-publication-contract",
      job: "prepare",
      message:
        "preparation must verify the public Cog release/provenance, generate with that tag, smoke-test SwiftPM, and record sibling main",
    });
  }
  // Toolchain policy — which runner, Xcode, and Swift may build a candidate —
  // is Cog's publisher's to enforce, and it already has before a release is
  // public. A second copy in the sibling can only drift, and did: it pinned
  // the self-hosted runner after Cog moved candidates to hosted macOS. The
  // sibling verifies identity (version, tree, checksum, architectures, both
  // probes) and nothing about how the bytes were produced.
  if (/\.build\.runner ==|xcode_version ==|xcode_build ==|swift_version/u.test(prepareSource)) {
    diagnostics.push({
      path: workflow.path,
      line: prepare?.line ?? 1,
      check: "coglint-publication-contract",
      job: "prepare",
      message:
        "preparation must verify provenance identity only; toolchain policy belongs to Cog's publisher and drifts when copied",
    });
  }

  const publishSource = publish?.steps.map((step) => step.run ?? "").join("\n") ?? "";
  if (
    publish === undefined ||
    !isHostedRunner(publish, "ubuntu-latest") ||
    !hasExactPermissions(publish.permissions, { contents: "write" }) ||
    environmentName(publish) !== "coglint-release" ||
    /\b(node|swift)\b/u.test(publishSource) ||
    !publishSource.includes("Sibling main moved") ||
    !publishSource.includes("generated_tree_hash") ||
    !publishSource.includes("Divergent immutable sibling tag") ||
    !publishSource.includes("Divergent published sibling tree") ||
    !publishSource.includes("already_published=true") ||
    !publishSource.includes('git commit -m "chore(release): publish CogLintPlugins ${VERSION}"') ||
    !publishSource.includes('git push --atomic origin HEAD:main "refs/tags/${VERSION}"') ||
    publishSource.includes("--force") ||
    publishSource.includes("--force-with-lease")
  ) {
    diagnostics.push({
      path: workflow.path,
      line: publish?.environmentLine ?? publish?.line ?? 1,
      check: "coglint-publication-contract",
      job: "publish",
      message:
        "protected sibling publication must only reverify bytes, require unchanged main, fast-forward the conventional commit, and create one immutable tag",
    });
  }

  const consumeSource = consume?.steps.map((step) => step.run ?? "").join("\n") ?? "";
  if (
    consume === undefined ||
    !isHostedRunner(consume, "macos-15") ||
    !hasExactContentsRead(consume.permissions) ||
    !consumeSource.includes("https://github.com/skeswa/coglint-plugins.git") ||
    !consumeSource.includes("swift build --package-path")
  ) {
    diagnostics.push({
      path: workflow.path,
      line: consume?.line ?? 1,
      check: "coglint-publication-contract",
      job: "consume",
      message: "final read-only verification must build a public exact-tag sibling consumer",
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

/** @param {import("./yaml.mjs").Node | null | undefined} permissions */
function hasExactPermissions(permissions, expected) {
  const permissionEntries = entries(permissions);
  const expectedEntries = Object.entries(expected);
  return (
    permissionEntries.length === expectedEntries.length &&
    expectedEntries.every(([scope, value]) =>
      permissionEntries.some((entry) => entry.key === scope && text(entry.value) === value),
    )
  );
}

/** @param {import("./model.mjs").Job} job */
function isHostedRunner(job, label) {
  return (
    job.runsOn.shape === "string" &&
    job.runsOn.labels.length === 1 &&
    job.runsOn.labels[0].value === label &&
    !classifyRunner(job.runsOn).selfHosted
  );
}

/** @param {import("./model.mjs").Job | undefined} job */
function environmentName(job) {
  if (job === undefined) return null;
  return text(job.environment) ?? text(get(job.environment, "name"));
}

/** @param {import("./model.mjs").Job} job */
function findActionStep(job, name) {
  return job.steps.find(
    (step) => step.uses !== null && actionName(step.uses).toLowerCase() === name.toLowerCase(),
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
  { name: "conventional-commits-contract", run: conventionalCommitsContract },
  { name: "release-workflow-contract", run: releaseWorkflowContract },
  { name: "coglint-publication-contract", run: cogLintPublicationContract },
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
