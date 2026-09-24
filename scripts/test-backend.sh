#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$PROJECT_ROOT"
export GOMODCACHE="${KEYBASE_MINIMAL_GOMODCACHE:-${GOMODCACHE:-$PROJECT_ROOT/build/go-mod}}"
export GOCACHE="${KEYBASE_MINIMAL_GOCACHE:-${GOCACHE:-$PROJECT_ROOT/build/go-cache}}"
export GOTOOLCHAIN=local GOWORK=off GOFLAGS= GOSUMDB=sum.golang.org
export GOPROXY=https://proxy.golang.org,direct
unset GOPRIVATE GONOSUMDB GONOPROXY
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi

"$PROJECT_ROOT/scripts/build-backend.sh" --prepare-only
cd "$PROJECT_ROOT/build/upstream/go"
# Existing upstream test helpers are excluded by the production tag. Test the
# fixed minimalist policy here, then compile production code separately below.
# Go 1.27 vet rejects legacy non-constant formatting in unrelated upstream wallet
# commands. Run the bounded policy tests without vet; do not patch those features
# back into the service merely to satisfy an unrelated legacy lint failure.
go test -vet=off -mod=readonly -tags minimalist ./chat ./service ./client ./libkb -run '^TestMinimalist' -count=1
# Existing offline upstream vectors exercise message integrity without an account.
go test -vet=off -mod=readonly -tags minimalist ./chat -run '^Test(V1Message[1-5]|RemarshalBoxed|VersionErrorBasic|VersionError|MakeOnePairwiseMAC)$' -count=1
go test -vet=off -mod=readonly -tags minimalist ./chat/signencrypt -run '^Test(Vectors|WholeRoundtrips|AssociatedData|BadSecretbox|InvalidSignature|ReencryptedPacketFails|TruncatedFails|PacketSwapInOneMessageFails|PacketSwapBetweenMessagesFails)$' -count=1
cd "$PROJECT_ROOT"
"$PROJECT_ROOT/scripts/build-backend.sh"
