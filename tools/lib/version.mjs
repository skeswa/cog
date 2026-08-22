import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

/** The repository root, resolved from this module so callers' cwd never matters. */
const REPO_ROOT = fileURLToPath(new URL("../..", import.meta.url));

/** Cog's single checked-in runtime version source. */
const VERSION_PATH = join(REPO_ROOT, "version.txt");

/** Reads and validates the current bare semantic version. */
export function currentVersion() {
  const version = readFileSync(VERSION_PATH, "utf8").trim();
  if (!/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(version)) {
    throw new Error(
      `version.txt does not contain one semantic version: ${JSON.stringify(version)}`,
    );
  }
  return version;
}
