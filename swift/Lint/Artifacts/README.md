# Generated CogLint artifacts

`mise run build:lint-artifact` builds the native macOS 14 `arm64` and
`x86_64` executables into `CogLintBinary.artifactbundle`, archives it as the
release asset `CogLintBinary.artifactbundle.zip`, and writes the SwiftPM
checksum beside the archive. These generated files are git-ignored; source,
pins, and the pipeline that reproduces them are committed instead.

Run `mise run test:lint-artifact` to rebuild the bundle and prove SwiftPM
selects and executes the exact metadata variant under both supported host
architectures. The release pipeline runs on the accepted Apple Silicon host,
using Rosetta to exercise the Intel selection path.
