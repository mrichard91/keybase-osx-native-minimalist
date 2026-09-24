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

Thread reading is an exception to substituting dummy components. The official
dummy thread loader returns an empty result, which would make the CLI thread API
silently show no messages. The minimalist service now wraps the official
blocking `UIThreadLoader.Load`, preserving its verified `ConvSource.Pull` path,
pagination, read-marking query, errors and connection state. It rejects the
optional predecoded-remote shortcut and `LoadNonblock`, which belong to rich UI
loading. A synthetic service-wiring test checks a returned message and page token,
both read-marking settings, error propagation, offline/reconnect state and early
rejection of those disabled paths.

The minimal unfurler reports mode NEVER and rejects attempts to enable another
mode. It does not write the full service's shared account preference. Account
configuration, socket/runtime paths, cache and Keychain service identifiers are
separate from the full service; connecting a minimal executable to an already
running full service would bypass these backend guarantees. Existing account
credentials must not be copied into that profile: the official provisioning
flow establishes the device.

The constructor also omits the optional loopback HTTP manager, wallet worker and
follower-list tracker loader. The tracker startup path is disabled at login as
well, so a successful account login cannot start that omitted worker.
Mobile-device provisioning displays the official text phrase while skipping QR
encoding, Unicode terminal graphics and the upstream temporary QR PNG file.
Focused tests cover these omissions; required account and key engines remain.

## Parser exclusions

Image-specific implementations are separated into `!minimalist` files, with
disabled substitutes under `minimalist`. The normal-build implementations retain
their original function bodies. The exclusions cover custom emoji file
validation, GIF-to-PNG conversion, audio waveform previews, coin-flip graphics,
bordered avatars and map decoration. Substitutes reject image operations before
opening, reading or rendering input; the coin-flip visualizer produces no image
and clears any existing visualization fields.

Removing the custom emoji decoder import also removes the retained
`camlistore.org/pkg/images` chain, including `nf/cr2`, TIFF, EXIF and fastjpeg.
The production dependency graph and binary-symbol inspection confirm that GIF,
PNG, TIFF and CR2 decoders and their initialization functions are absent. This
requires file-level import separation: a disabled call alone can still retain a
Go package's decoder-registration initializer. The build's surface checker also
enforces the named image-package exclusions against bounded native symbol output
and explicitly records retained JPEG. This is a regression check, not a complete
inventory of parsers or transitive system dependencies.

JPEG remains. The official `go-crypto/openpgp/packet` package imports `image/jpeg`
for `NewUserAttributePhoto`, a photo-encoding helper. That import retains JPEG's
decoder-registration initializer. Review of the source files selected by
`production,minimalist` found no current caller of the photo constructor or the
image/JPEG decoders in retained application or third-party code. OpenPGP user
attribute parsing and serialization handle opaque bytes; they do not decode the
embedded photo. This distinguishes retained decoder code from an identified
untrusted-image decoding path. It is source-level evidence, not a proof of total
unreachability or protection from future call paths.

The crypto dependency remains unchanged for this acceptance build. Removing JPEG
would require a separately reviewed dependency change and reproducible provenance
for that patched dependency. Other retained protocol and general-purpose parsers
still need review.

## Verification and remaining work

`TestMinimalist*` tests in the patched `go/chat` package cover the strict text
boundary, typed metadata and privacy checks, early rejection before callbacks,
old-outbox rejection, preserved conversation initialization, emoji-source
bypass, no-op incoming decoration, and rejection by image-processing substitutes.
Service tests also cover the actual blocking thread-loader wiring. These tests
need no login, account mutation or message sending.

Run the policy tests and production build with `bash scripts/test-backend.sh`.
The existing upstream chat tests import `externalstest`, which is excluded by
the production build tag. Build the actual executable separately with
`go build -tags 'production minimalist' ./keybase` to verify production code.

The parser exclusions above are verified for the rebuilt helper, not a claim
that every unused dependency has disappeared. Imports, initialization functions
and retained RPC implementations still require review. The dated
[validation record](VALIDATION.md) distinguishes rebuilt-helper checks from
earlier packaged-app checks and pending live acceptance.

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
