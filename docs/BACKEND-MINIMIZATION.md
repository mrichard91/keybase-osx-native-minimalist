# Minimal official backend

The native frontend originally used the installed official Keybase service. That
removed Electron but left the full service's rich-message processing active. The
packaged implementation uses a pinned official Go source tree with a compile-time
`minimalist` policy. It keeps Keybase's accounts, device provisioning, identity
verification, encryption, team key handling, inbox and message protocol.

The source baseline is
[`f60f2ff97e35f2287375d95eafa7cad77d872072`](https://github.com/keybase/client/commit/f60f2ff97e35f2287375d95eafa7cad77d872072).
`production` selects production defaults; it is not an upstream minimal-feature
build. The added `libkb.IsMinimalistBuild` constant is true only with the new
`minimalist` build tag. An account preference or command argument cannot disable
the policy.

## Implemented chat boundaries

- `Server.PostLocal` and `PostLocalNonblock` reject public/non-chat messages,
  non-text message kinds, non-ASCII/control content, empty/oversized text, and
  typed payment, emoji, mention, location, reply and ephemeral
  payloads before touching service callbacks. Both paths bypass built-in command
  and in-chat payment parsing in the minimalist build.
- `BlockingSender.Send` validates the actual verified conversation before joining
  or posting. `Prepare` also rejects unsupported sends, including items already
  present in an outbox. TEXT remains subject to the strict boundary. Internal
  TLFNAME, METADATA, JOIN, LEAVE, SYSTEM, DELETE and DELETEHISTORY control messages
  remain available; their header and body types must agree, except for the
  official empty TLFNAME initialization message.
- The sender bypasses emoji harvesting, reply/mention decoration, outgoing rich
  UI activity, unfurls, location tracking and journey-card activity. Plain text
  containing a custom-looking shortcode, payment-looking text or a Giphy URL
  cannot activate those subsystems in this backend.
- Incoming new-message pushes retain the official verified cache, inbox and
  inbox-version updates, then stop before coin-flip handling, rich UI
  presentation, reply filling and desktop notification snippets. The frontend
  reads the verified JSON thread API by polling.
- Conversation-source paths bypass pending attachment previews, asset-deletion
  jobs and journey-card generation. This also avoids dereferencing the omitted
  journey-card manager during an ordinary thread read.

The [official first-message code](https://github.com/keybase/client/blob/f60f2ff97e35f2287375d95eafa7cad77d872072/go/chat/helper.go#L1371)
requires TLFNAME or METADATA to create a conversation, which is why simply
blocking every non-TEXT message in the lower sender would break normal use.
User-facing post RPCs still accept TEXT only.

## Service wiring and isolation

The service patch replaces rich components with no-op implementations and limits
registered RPC methods to configuration/handshake reads, login/logout, signup,
CLI logging registration, and 13 text-chat methods. User/avatar, device
administration, account deletion, attachment, wallet, filesystem, search and bot
RPCs are not registered. Account engines still perform required identity, device
and key operations directly within the official service. Official reusable implementations in
[`go/chat/types/types.go`](https://github.com/keybase/client/blob/f60f2ff97e35f2287375d95eafa7cad77d872072/go/chat/types/types.go#L401)
include attachment URL/fetcher/uploader, unfurler, emoji source, Stellar
sender/loader, indexer, coin-flip manager and bot manager substitutes. They must
not be installed as `nil`: ordinary synchronization and storage code still
calls several of these interfaces. Some official dummy methods report empty
success, so denying unsupported RPC methods before argument decoding is also
necessary.

The minimal unfurler reports mode NEVER and rejects attempts to enable another
mode. It does not write the full service's shared account preference. Account
configuration, socket/runtime paths, cache and Keychain service identifiers are
separate from the full service; connecting a minimal executable to an already
running full service would bypass these backend guarantees. Existing account
credentials must not be copied into that profile: the official provisioning
flow establishes the device.

The constructor also omits the optional loopback HTTP manager and wallet worker.
Mobile-device provisioning displays the official text phrase while skipping QR
encoding, Unicode terminal graphics and the upstream temporary QR PNG file.
Focused tests cover both omissions; required account and key engines remain.

## Verification and remaining work

`TestMinimalist*` tests in the patched `go/chat` package cover the strict text
boundary, typed metadata and privacy checks, early rejection before callbacks,
old-outbox rejection, preserved conversation initialization, emoji-source
bypass, and no-op incoming decoration. These tests need no login, account
mutation or message sending.

Run the policy tests and production build with `bash scripts/test-backend.sh`.
The existing upstream chat tests import `externalstest`, which is excluded by
the production build tag. Build the actual executable separately with
`go build -tags 'production minimalist' ./keybase` to verify production code.

The first backend patch gates execution and removes selected native media
helpers. It does not by itself prove that all unused Go dependencies disappear
from the resulting executable. Imports, initialization functions and retained
RPC implementations require a separate linked-binary review and further
build-tag file separation.

Incoming encrypted messages still use official typed protocol decoding,
including attachment metadata. Media is not fetched or rendered by those gates,
but metadata parsing has not been removed. A later narrow decoder must preserve
header signatures, sender/device validation, ciphertext-body hashes and message
chain checks before omitting an unsupported body. In the
[MBV2+ unbox path](https://github.com/keybase/client/blob/f60f2ff97e35f2287375d95eafa7cad77d872072/go/chat/boxer.go#L933),
the signed header and body hash are verified before body decoding. The older
[MBV1 path](https://github.com/keybase/client/blob/f60f2ff97e35f2287375d95eafa7cad77d872072/go/chat/boxer.go#L578)
decodes the body earlier and needs a separately reviewed reordering. Silently
trusting an unsigned outer message type, dropping messages before verification,
or rewriting cryptographic checks is not an acceptable shortcut.

Live owner-controlled provisioning, direct/group/team interoperability and
message edit/delete behavior remain acceptance requirements. Backend unit tests
cannot establish those server and device interactions.
