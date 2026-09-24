# Official backend with a fixed minimal policy

`upstream.json` pins the official Keybase repository and an immutable commit.
`patches/minimalist.patch` contains this project's changes. The `minimalist`
build tag fixes the reduced behavior at compile time; an account preference or
command flag cannot enable the omitted features.

## Build

Requirements: macOS, Git, Python 3, Go at least as new as the upstream `go.mod`
requires, and Xcode or Command Line Tools with the macOS SDK. The script uses the
installed Go toolchain (`GOTOOLCHAIN=local`) and never installs another toolchain
automatically. Network access is needed for the source and dependencies on the
first build.

From the repository root:

```sh
scripts/build-backend.sh
scripts/test-backend.sh
```

The outputs are `build/backend/keybase-minimalist`,
`build/backend/backend.json`, `build/backend/surface-report.json` and
`build/backend/THIRD-PARTY-NOTICES.txt`. The executable is signed with hardened runtime and
an ad-hoc identity by default. Set `KEYBASE_MINIMAL_SIGN_IDENTITY` to a local
signing identity when needed. These local signatures omit a signing timestamp;
distribution signing and notarization remain a separate release step. Changing
the helper's signature changes its SHA-256, so its manifest and containing app
must be rebuilt together.

The manifest records policy version 1, the exact upstream commit, the signed
binary's SHA-256, the checked-in patch's SHA-256 and the Go version used to compile
the official code. It also records the target OS/architecture. The app packages
the executable and manifest together inside its signed bundle.
Before writing the manifest, the build checks the helper's fixed
`--minimalist-build-info` diagnostic against the expected policy and source pin.
That early-exit path does not initialize account configuration or the service.
The surface checker also rejects direct links to prohibited UI/media frameworks,
records retained Go modules, and uses bounded `/usr/bin/nm` output to reject
symbols from the removed image packages. It explicitly reports retained JPEG
symbols. This checks named packages, not every parser or transitive system
dependency. The notices collector gathers available license
texts for linked modules and reports missing coverage explicitly.
The current rebuilt helper records 74 modules and 90 collected notice files, with
two missing/incomplete notice entries. These counts describe collected evidence,
not complete license coverage; see the dated [validation record](../docs/VALIDATION.md).

## Source and dependency checks

The script creates `build/upstream` only when it is absent, using a sparse
checkout of `go` fetched directly at the pinned commit with depth one. Unrelated
branch history and file blobs are not fetched. It starts from a clean checkout, restricts
patch paths to `go/`, applies the patch to both the working tree and Git index,
and records the exact resulting staged tree in a private Git metadata file.

Subsequent builds verify the origin, HEAD, patch hash, staged tree, working files
and absence of additional files, including ignored files. Unexpected source
changes cause an error. The script never resets or cleans an existing checkout.
If the patch changes, or preparation was interrupted, inspect and move
`build/upstream` aside before rebuilding. Preserve any work you want to keep.
The output directory is also marked as managed before artifacts are replaced;
an existing unknown `build/backend` directory is left untouched.

Go dependencies are checked against the pinned `go.sum` and the public Go
checksum database, followed by `go mod verify`. Source checks run again after
dependency preparation and compilation. `-mod=readonly` prevents compilation
from updating the dependency lock. `-trimpath`, a cleared build ID and disabled
VCS stamping avoid embedding local source paths or working-tree state.

Caches default to `build/go-mod` and `build/go-cache`. Existing `GOMODCACHE` and
`GOCACHE` values are respected; the task-specific overrides
`KEYBASE_MINIMAL_GOMODCACHE` and `KEYBASE_MINIMAL_GOCACHE` take precedence. The
script fixes the public module proxy/checksum service and disables private-module
checksum exemptions for this public dependency tree.

Source and policy provenance are repeatable; byte-identical binaries also depend
on using the same Go version, architecture, SDK, native compiler and signing
identity. The manifest reports the actual Go version instead of claiming a
fully reproducible result across different machines.

## Tests and scope

After a build, `python3 scripts/smoke-backend.py` starts only a fresh temporary,
logged-out profile. Its child processes use a fixture home and file secret store,
so the test does not query the user's Keychain. Remote API requests are forced to
closed loopback port `127.0.0.1:1`, and push is disabled. It checks that the service
opens its namespaced Unix socket, has no listening TCP socket, reports logged-out
status, refuses attachment APIs and shuts down cleanly. Output and execution time
are bounded. Successful fixtures are removed; failed fixtures are retained for
inspection. `--keep-fixture` preserves a successful fixture too. Local Unix socket
permissions are required; the test must not be redirected to a real profile.


`test-backend.sh` prepares and verifies the source, then runs the
`TestMinimalist*` tests in `chat`, `service`, `client` and `libkb`, plus selected
existing offline message-boxing and authenticated-encryption vectors. The
vectors cover malformed versions, message remarshal, pairwise MACs, associated
data, invalid signatures, truncation and packet swapping. These tests do not
require a real login or live chat. The existing upstream test helpers
are excluded under the `production` tag, so tests use `minimalist`; the script
then separately builds with both `production` and `minimalist` and signs the
result. Live provisioning and messaging are separate owner-controlled acceptance
tests. `python3 scripts/smoke-backend.py` exercises a fresh logged-out profile
with file-only test secret storage, a closed loopback API address and no TCP
listeners; it never provisions an account.

These bounded tests use `-vet=off`: Go 1.27's vet rejects non-constant format
strings in unrelated legacy upstream wallet commands while compiling the client
test package. The selected policy tests still run, and production compilation
is checked separately. This does not claim that the full upstream tree passes
modern vet or a security audit.

The patch gates rich-message actions, removes native media helpers and the
GIF/PNG/TIFF/CR2 parser imports, and limits exposed service methods. The official
blocking thread reader remains connected to the verified conversation source;
a synthetic wiring test covers message results, pagination and source failures.
It preserves the official identity and cryptographic implementation. JPEG remains
linked through the unchanged official OpenPGP photo helper. These exclusions do
not prove every unused dependency or protocol decoder has been removed. Incoming
encrypted messages still pass through official metadata decoding, and remaining
linked dependencies need review as the backend is reduced further. See
[backend minimization](../docs/BACKEND-MINIMIZATION.md) and
[the security model](../SECURITY.md).

A minimal executable must use its own profile, runtime socket, caches and
Keychain namespace. Connecting it to a full Keybase service would restore that
service's behavior. Device setup uses the official provisioning flow; the build
scripts do not copy credentials or contact a logged-in account.
