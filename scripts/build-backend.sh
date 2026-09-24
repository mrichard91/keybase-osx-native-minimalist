#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PREPARE_ONLY=false
case "${1:-}" in
    "") ;;
    --prepare-only) PREPARE_ONLY=true ;;
    *) printf '%s\n' "Usage: scripts/build-backend.sh [--prepare-only]" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then printf '%s\n' "Too many arguments." >&2; exit 2; fi

die() { printf 'Backend build stopped: %s\n' "$*" >&2; exit 1; }
for backend_tool in git python3 go; do command -v "$backend_tool" >/dev/null || die "Install $backend_tool first."; done
[ "$(uname -s)" = Darwin ] || die "This backend build requires macOS and its native Keychain frameworks."

BUILD_ROOT="$PROJECT_ROOT/build"
SOURCE_ROOT="$BUILD_ROOT/upstream"
OUTPUT_ROOT="$BUILD_ROOT/backend"
PATCH_FILE="$PROJECT_ROOT/backend/patches/minimalist.patch"
UPSTREAM_FILE="$PROJECT_ROOT/backend/upstream.json"
[ -f "$PATCH_FILE" ] && [ -f "$UPSTREAM_FILE" ] || die "The checked-in upstream lock and policy patch are required."
[ ! -L "$BUILD_ROOT" ] && [ ! -L "$SOURCE_ROOT" ] && [ ! -L "$OUTPUT_ROOT" ] || die "Build paths must not be symbolic links."
mkdir -p "$BUILD_ROOT"

# Do not let an inherited Git index/worktree redirect writes to another checkout.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
git_source() { git -c core.hooksPath=/dev/null -c core.autocrlf=false -C "$SOURCE_ROOT" "$@"; }

LOCK_DIRECTORY="$BUILD_ROOT/.backend-build-lock"
mkdir "$LOCK_DIRECTORY" 2>/dev/null || die "Another backend preparation is running, or an interrupted build left build/.backend-build-lock. Inspect it before removing that empty lock directory."
TEMP_BINARY=""
TEMP_MANIFEST=""
TEMP_REPORT=""
TEMP_NOTICES=""
cleanup() {
    [ -z "$TEMP_BINARY" ] || rm -f "$TEMP_BINARY"
    [ -z "$TEMP_MANIFEST" ] || rm -f "$TEMP_MANIFEST"
    [ -z "$TEMP_REPORT" ] || rm -f "$TEMP_REPORT"
    [ -z "$TEMP_NOTICES" ] || rm -f "$TEMP_NOTICES"
    rmdir "$LOCK_DIRECTORY" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

LOCK_VALUES="$(python3 - "$UPSTREAM_FILE" "$PATCH_FILE" <<'PY'
import hashlib, json, pathlib, re, sys
lock = json.loads(pathlib.Path(sys.argv[1]).read_text())
repo, commit = lock.get('repository'), lock.get('commit')
if repo != 'https://github.com/keybase/client.git' or not isinstance(commit, str) or not re.fullmatch(r'[0-9a-f]{40}', commit):
    raise SystemExit('upstream.json must pin the official Keybase repository and a full commit SHA')
print(repo + '\t' + commit + '\t' + hashlib.sha256(pathlib.Path(sys.argv[2]).read_bytes()).hexdigest())
PY
)"
IFS=$'\t' read -r UPSTREAM_REPOSITORY UPSTREAM_COMMIT PATCH_SHA256 <<< "$LOCK_VALUES"
SOURCE_STATE="$SOURCE_ROOT/.git/minimalist-source-state.json"

verify_source() {
    [ -d "$SOURCE_ROOT/.git" ] && [ ! -L "$SOURCE_ROOT/.git" ] && [ -f "$SOURCE_STATE" ] && [ ! -L "$SOURCE_STATE" ] ||
        die "build/upstream is not a managed checkout. Inspect and move it aside; this script will not reset or delete it."
    [ "$(git_source rev-parse --show-toplevel)" = "$SOURCE_ROOT" ] || die "Unexpected checkout root."
    [ "$(git_source rev-parse HEAD)" = "$UPSTREAM_COMMIT" ] || die "The upstream checkout is no longer at the pinned commit."
    [ "$(git_source remote get-url origin)" = "$UPSTREAM_REPOSITORY" ] || die "The checkout origin does not match upstream.json."
    git_source diff --quiet --ignore-submodules=none || die "Upstream working files were edited. Inspect and move build/upstream aside to prepare a fresh copy."
    [ -z "$(git_source ls-files --others)" ] || die "Upstream contains additional files. Preserve them and move the checkout aside before rebuilding."
    local current_tree
    current_tree="$(git_source write-tree)"
    python3 - "$SOURCE_STATE" "$UPSTREAM_REPOSITORY" "$UPSTREAM_COMMIT" "$PATCH_SHA256" "$current_tree" <<'PY'
import json, pathlib, sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text())
expected = dict(schemaVersion=1, repository=sys.argv[2], commit=sys.argv[3], patchSHA256=sys.argv[4], stagedTree=sys.argv[5])
if state != expected:
    raise SystemExit('Managed source or patch changed. Inspect and move build/upstream aside; no reset or cleanup was performed.')
PY
}

if [ -e "$SOURCE_ROOT" ]; then
    verify_source
else
    printf '%s\n' "Fetching the pinned official Keybase source..."
    git -c core.hooksPath=/dev/null -c core.autocrlf=false init "$SOURCE_ROOT"
    git_source remote add origin "$UPSTREAM_REPOSITORY"
    git_source config remote.origin.promisor true
    git_source config remote.origin.partialclonefilter blob:none
    git_source sparse-checkout init --cone
    git_source sparse-checkout set go
    git_source fetch --depth=1 --filter=blob:none --no-tags origin "$UPSTREAM_COMMIT"
    git_source -c advice.detachedHead=false checkout --detach "$UPSTREAM_COMMIT"
    [ "$(git_source rev-parse HEAD)" = "$UPSTREAM_COMMIT" ] || die "Fetched commit does not match the lock."
    [ -z "$(git_source status --porcelain=v1 --untracked-files=all)" ] || die "Fresh upstream checkout is not clean."
    # All policy edits must stay in the official Go tree. Git also rejects unsafe
    # paths; the explicit check prevents accidental patching of unrelated files.
    git_source apply --numstat -z "$PATCH_FILE" | python3 -c '
import pathlib, sys
records = sys.stdin.buffer.read().split(b"\0")
count = 0
for record in records:
    if not record: continue
    fields = record.split(b"\t", 2)
    if len(fields) != 3: raise SystemExit("Unsupported patch path format")
    path = fields[2].decode("utf-8")
    parts = pathlib.PurePosixPath(path).parts
    if not path.startswith("go/") or ".." in parts or len(parts) < 2:
        raise SystemExit("Policy patch may edit only paths inside go/")
    count += 1
if count == 0: raise SystemExit("Policy patch is empty")
'
    git_source apply --check --index "$PATCH_FILE"
    git_source apply --index --whitespace=error "$PATCH_FILE"
    STAGED_TREE="$(git_source write-tree)"
    python3 - "$SOURCE_STATE" "$UPSTREAM_REPOSITORY" "$UPSTREAM_COMMIT" "$PATCH_SHA256" "$STAGED_TREE" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
with path.open('x') as stream:
    json.dump(dict(schemaVersion=1, repository=sys.argv[2], commit=sys.argv[3], patchSHA256=sys.argv[4], stagedTree=sys.argv[5]), stream, indent=2)
    stream.write('\n')
PY
    verify_source
fi

export GOMODCACHE="${KEYBASE_MINIMAL_GOMODCACHE:-${GOMODCACHE:-$BUILD_ROOT/go-mod}}"
export GOCACHE="${KEYBASE_MINIMAL_GOCACHE:-${GOCACHE:-$BUILD_ROOT/go-cache}}"
export GOTOOLCHAIN=local GOWORK=off GOFLAGS= GOSUMDB=sum.golang.org
export GOPROXY=https://proxy.golang.org,direct
unset GOPRIVATE GONOSUMDB GONOPROXY
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi
cd "$SOURCE_ROOT/go"
printf '%s\n' "Verifying pinned Go dependencies..."
go mod download
go mod verify
verify_source
if "$PREPARE_ONLY"; then printf '%s\n' "Pinned, patched backend source is ready."; exit 0; fi

OUTPUT_MARKER="$OUTPUT_ROOT/.minimalist-build-output"
if [ -e "$OUTPUT_ROOT" ]; then
    [ -d "$OUTPUT_ROOT" ] && [ -f "$OUTPUT_MARKER" ] && [ ! -L "$OUTPUT_MARKER" ] &&
        [ "$(cat "$OUTPUT_MARKER")" = 'Keybase Minimal backend output v1' ] ||
        die "build/backend is not a managed output directory. Inspect and move it aside before building."
else
    mkdir "$OUTPUT_ROOT"
    printf '%s\n' 'Keybase Minimal backend output v1' > "$OUTPUT_MARKER"
fi
[ ! -L "$OUTPUT_ROOT/keybase-minimalist" ] && [ ! -L "$OUTPUT_ROOT/backend.json" ] &&
    [ ! -L "$OUTPUT_ROOT/surface-report.json" ] &&
    [ ! -L "$OUTPUT_ROOT/THIRD-PARTY-NOTICES.txt" ] || die "Output artifacts must not be symbolic links."
TEMP_BINARY="$(mktemp "$OUTPUT_ROOT/.keybase-minimalist.XXXXXX")"
TEMP_MANIFEST="$(mktemp "$OUTPUT_ROOT/.backend-manifest.XXXXXX")"
TEMP_REPORT="$(mktemp "$OUTPUT_ROOT/.surface-report.XXXXXX")"
TEMP_NOTICES="$(mktemp "$OUTPUT_ROOT/.third-party-notices.XXXXXX")"
printf '%s\n' "Building the production minimalist backend..."
go build -mod=readonly -trimpath -buildvcs=false -tags production,minimalist -ldflags=-buildid= -o "$TEMP_BINARY" ./keybase
verify_source
chmod 755 "$TEMP_BINARY"
/usr/bin/codesign --force --options runtime --timestamp=none \
    --identifier io.github.mrichard91.keybase-minimal.backend --sign "${KEYBASE_MINIMAL_SIGN_IDENTITY:--}" "$TEMP_BINARY"
/usr/bin/codesign --verify --strict "$TEMP_BINARY"
# The checker uses a fixed early-exit diagnostic before account/service startup,
# validates direct native dependencies, and records retained Go module metadata.
python3 "$PROJECT_ROOT/scripts/check-backend-surface.py" --binary "$TEMP_BINARY" \
    --upstream "$UPSTREAM_COMMIT" --report "$TEMP_REPORT"
python3 "$PROJECT_ROOT/scripts/collect-backend-notices.py" --binary "$TEMP_BINARY" \
    --source "$SOURCE_ROOT" --module-cache "$GOMODCACHE" --upstream "$UPSTREAM_COMMIT" \
    --output "$TEMP_NOTICES"
verify_source
GO_VERSION="$(go env GOVERSION)"
GO_OS="$(go env GOOS)"
GO_ARCH="$(go env GOARCH)"
python3 - "$TEMP_MANIFEST" "$TEMP_BINARY" "$UPSTREAM_REPOSITORY" "$UPSTREAM_COMMIT" "$PATCH_SHA256" "$GO_VERSION" "$GO_OS" "$GO_ARCH" <<'PY'
import hashlib, json, pathlib, sys
manifest = dict(schemaVersion=1, policy=1, upstream=sys.argv[4], repository=sys.argv[3],
                binarySHA256=hashlib.sha256(pathlib.Path(sys.argv[2]).read_bytes()).hexdigest(),
                patchSHA256=sys.argv[5], officialGoVersion=sys.argv[6], goOS=sys.argv[7], goArch=sys.argv[8])
pathlib.Path(sys.argv[1]).write_text(json.dumps(manifest, indent=2) + '\n')
PY
mv -f "$TEMP_BINARY" "$OUTPUT_ROOT/keybase-minimalist"
TEMP_BINARY=""
mv -f "$TEMP_MANIFEST" "$OUTPUT_ROOT/backend.json"
TEMP_MANIFEST=""
mv -f "$TEMP_REPORT" "$OUTPUT_ROOT/surface-report.json"
TEMP_REPORT=""
mv -f "$TEMP_NOTICES" "$OUTPUT_ROOT/THIRD-PARTY-NOTICES.txt"
TEMP_NOTICES=""
printf '%s\n' "$OUTPUT_ROOT/keybase-minimalist" "$OUTPUT_ROOT/backend.json"
