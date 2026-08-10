// The workflow-contract checks.
//
// Each check is a named function over one `Workflow` from `model.mjs` and
// returns diagnostics. `WORKFLOW_CHECKS` is the ordered registry the CLI runs;
// later hardening slices append to it rather than editing existing checks.

import { entries, text } from "./yaml.mjs";

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

/** The action whose checkout token must not be left on disk. */
const CHECKOUT_ACTION = "actions/checkout";

/** A full-length, lowercase commit SHA. */
const FULL_SHA = /^[0-9a-f]{40}$/;

/** An image digest, the only pinnable form of a `docker://` reference. */
const IMAGE_DIGEST = /@sha256:[0-9a-f]{64}$/;

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
    for (const problem of gradePermissions(own, job.permissionsLine)) {
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

    const ref = reference.slice(at + 1);
    if (FULL_SHA.test(ref)) return;
    const detail = /^[0-9a-fA-F]{40}$/.test(ref)
      ? "a commit SHA must be lowercase"
      : /^[0-9a-f]{7,39}$/.test(ref)
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

/** The ordered registry the CLI runs. */
export const WORKFLOW_CHECKS = [
  { name: "no-pull-request-target", run: noPullRequestTarget },
  { name: "self-hosted-guard", run: selfHostedGuard },
  { name: "least-privilege-permissions", run: leastPrivilegePermissions },
  { name: "credential-hygiene", run: credentialHygiene },
  { name: "job-timeout", run: jobTimeout },
  { name: "sha-pinned-actions", run: shaPinnedActions },
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
function gradePermissions(node, line) {
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
    problems.push({
      line: entry.line,
      message: `grants \`${entry.key}: ${value}\`; only \`read\` or \`none\` is allowed`,
    });
  }
  return problems;
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
