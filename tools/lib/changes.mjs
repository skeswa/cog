import { spawnSync } from "node:child_process";

/** Runs a source-control query and returns its stdout or throws with context. */
function run(command, arguments_, cwd) {
  const result = spawnSync(command, arguments_, {
    cwd,
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error !== undefined) throw result.error;
  if (result.status !== 0) {
    throw new Error(
      `${command} ${arguments_.join(" ")} exited ${result.status}:\n${result.stderr || result.stdout}`,
    );
  }
  return result.stdout;
}

/** Reads one Git commit without relying on delimiter-sensitive log formatting. */
function readGitCommit(cwd, id) {
  const author = run("git", ["show", "-s", "--format=%an%n%ae", id], cwd).trimEnd().split("\n");
  const message = run("git", ["show", "-s", "--format=%B", id], cwd).trimEnd();
  return { id, authorName: author[0] ?? "", authorEmail: author[1] ?? "", message };
}

/** Collects every Git commit in one authoritative oldest-first range. */
export function collectGitCommits(cwd, from, to) {
  const ids = run("git", ["rev-list", "--reverse", `${from}..${to}`], cwd)
    .trim()
    .split("\n")
    .filter(Boolean);
  return ids.map((id) => readGitCommit(cwd, id));
}

/** Collects all ancestors through one Git revision, including the root commit. */
export function collectGitAncestors(cwd, to) {
  const ids = run("git", ["rev-list", "--reverse", to], cwd).trim().split("\n").filter(Boolean);
  return ids.map((id) => readGitCommit(cwd, id));
}

/** Reads one jj revision's author and description through the stable template API. */
function readJjRevision(cwd, id) {
  const output = run(
    "jj",
    [
      "log",
      "-r",
      id,
      "--no-graph",
      "-T",
      'author.name() ++ "\\n" ++ author.email() ++ "\\n" ++ description',
    ],
    cwd,
  );
  const [authorName = "", authorEmail = "", ...description] = output.split("\n");
  return { id, authorName, authorEmail, message: description.join("\n").trimEnd() };
}

/** Collects the non-empty jj descriptions in one oldest-first revset. */
export function collectJjRevisions(cwd, revset = "main..@") {
  const ids = run(
    "jj",
    ["log", "-r", revset, "--no-graph", "--reversed", "-T", 'commit_id ++ "\\n"'],
    cwd,
  )
    .trim()
    .split("\n")
    .filter(Boolean);
  return ids.map((id) => readJjRevision(cwd, id)).filter((commit) => commit.message.trim() !== "");
}

/** Resolves the authoritative Git range encoded by a GitHub event payload. */
export function commitsForGitHubEvent(cwd, eventName, event) {
  if (eventName === "pull_request") {
    return collectGitCommits(cwd, event.pull_request.base.sha, event.pull_request.head.sha);
  }
  if (eventName === "push") {
    const before = event.before;
    const after = event.after;
    if (/^0+$/.test(before)) return collectGitAncestors(cwd, after);
    return collectGitCommits(cwd, before, after);
  }
  throw new Error(`unsupported GitHub event for revision linting: ${eventName}`);
}

/** True only for the repository owner in CI or the owner's local author identity. */
export function releaseAsMaintainer(commit, environment = process.env) {
  if (environment.GITHUB_ACTIONS === "true") return environment.GITHUB_ACTOR === "skeswa";
  return commit.authorEmail.toLowerCase() === "me@sandile.io";
}

/** Whether a description asks Release Please to force a version. */
export function hasReleaseAs(message) {
  return /^Release-As:\s*\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?\s*$/imu.test(message);
}
