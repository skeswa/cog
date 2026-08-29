import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const REPO_ROOT = fileURLToPath(new URL("../..", import.meta.url));
const STABLE_RELEASE = /^\d+\.\d+\.\d+$/u;

/**
 * Resolves the published Swift release shown by the documentation site.
 *
 * CI supplies the release returned by GitHub's public `releases/latest` API,
 * keeping the VitePress copy aligned with the DocC archive in the same Pages
 * artifact. Local builds use the newest stable tag in the checkout so previews
 * need no network access and never mistake a release candidate for a release.
 */
export function resolveSwiftRelease(environment = process.env, listTags = localReleaseTags) {
  const supplied = environment.COG_DOCS_RELEASE_VERSION?.trim();
  if (supplied !== undefined) return requireStableRelease(supplied, "COG_DOCS_RELEASE_VERSION");

  const [latest] = listTags()
    .map((tag) => tag.trim())
    .filter((tag) => STABLE_RELEASE.test(tag))
    .sort(compareReleasesDescending);
  if (latest === undefined) {
    throw new Error("the documentation site requires a stable release tag");
  }
  return latest;
}

/** Lists tags without consulting a remote service during a local site build. */
function localReleaseTags() {
  return execFileSync("git", ["tag", "--list"], {
    cwd: REPO_ROOT,
    encoding: "utf8",
  }).split("\n");
}

/** Rejects draft, prerelease, prefixed, and otherwise ambiguous versions. */
function requireStableRelease(version, source) {
  if (!STABLE_RELEASE.test(version)) {
    throw new Error(`${source} is not a bare stable semantic version: ${JSON.stringify(version)}`);
  }
  return version;
}

/** Orders bare semantic versions numerically rather than lexicographically. */
function compareReleasesDescending(left, right) {
  const leftParts = left.split(".").map(Number);
  const rightParts = right.split(".").map(Number);
  for (let index = 0; index < 3; index += 1) {
    if (leftParts[index] !== rightParts[index]) return rightParts[index] - leftParts[index];
  }
  return 0;
}
