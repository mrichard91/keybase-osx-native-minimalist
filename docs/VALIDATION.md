# Validation record

Checked locally on 2026-09-24 with Apple Swift 6.4, Go 1.27.1 and macOS 27 arm64.
The backend source is official Keybase revision
`f60f2ff97e35f2287375d95eafa7cad77d872072` plus the checked-in minimalist patch.

- 75 Swift tests passed: ASCII/emoji policy, API request shapes, identity/private
  conversation checks, bounded child processes, cancellation and cleanup,
  synthetic account terminals, signed-backend validation, AppKit editing, draft
  isolation, account changes, and setup/compatibility presentation.
- Pagination fixtures use the official serialized response, where `last` is
  omitted when false. The next-page cursor is retained in that case; numeric,
  string and other malformed `last` values are rejected.
- Account submission uses terminal Return (CR), matching the official raw
  terminal reader. A live username prompt exposed the earlier LF bug; it is
  covered by a mixed canonical/raw/secret-prompt fixture and an inert run of
  Keybase's actual terminal reader.
- 17 backend policy tests passed from freshly prepared pinned/patched source.
  They cover private ASCII posts, typed extras, internal conversation control
  messages, queued sends, optional-action bypasses, exact RPC surface, fixed
  preview policy, separate storage/Keychain names, inert constructor services,
  text-only mobile provisioning without a temporary QR image, and rejection by
  the removed image-processing functions before input is read or rendered.
  Constructor checks also verify that the optional follower-list worker is
  absent and its login startup and request paths remain disabled.
- The synthetic service-wiring test exercises the actual blocking thread loader
  against a supplied conversation source. It verifies a message and page token
  survive, both read-marking settings are preserved, source errors propagate,
  offline/reconnect state is retained, and rich/shortcut loading is rejected.
  This catches the previous dummy loader's silent empty-thread result without
  reading real messages or testing server interoperability.
- 18 existing offline Keybase crypto tests passed with the minimalist tag:
  signed/encrypted legacy message vectors, versions, remarshal, pairwise MACs,
  associated data, invalid signatures, truncation and swapped packets.
- A clean source fetch, patch application, module checksum verification and
  production backend build passed through the repository scripts.
- The rebuilt production backend started in a fresh temporary profile with
  filesystem-only test secret storage, push disabled, and its API pointed at
  closed loopback port 1. The CLI reached its service, remained logged out, and
  rejected attachment API calls. No TCP listeners appeared, shutdown exited 0,
  and the fixture was removed. No real Keybase account was used.
- An updated release app was built separately at
  `build/staged/Keybase Minimal.app`; its hardened-runtime signature verified and
  packaged self-check passed for emoji resources, AppKit text input, the rebuilt
  backend signature/hash, and a configuration-free version subprocess. The
  existing app used for owner provisioning was not replaced during that session.
  After provisioning completed, the verified app was installed at
  `build/Keybase Minimal.app` with the old bundle retained separately.
- 24 build-inspection fixture tests passed, including malformed policy metadata,
  forbidden direct frameworks and image-package symbols, process limits and
  notice provenance boundaries.
- Real macOS signing tests accepted a valid synthetic app/helper bundle and
  rejected a modified manifest, modified helper, and removal of both assets.
- The binary inspection records direct Mach-O dependencies and embedded Go module
  provenance in `build/backend/surface-report.json`. It rejects direct links to
  the listed media/browser frameworks. The rebuilt helper records 74 dependency
  modules; its notices contain 90 collected files and two missing/incomplete
  entries (`github.com/keybase/stellarnet` and `github.com/segmentio/go-loggly`).
  Collected notices are not a complete license review.
- Production dependency-graph and binary-symbol inspection confirm GIF, PNG,
  TIFF and CR2 decoder packages/initializers are absent, along with the
  camlistore/EXIF image-decoding chain. JPEG remains through the unchanged
  official OpenPGP packet package's photo-encoding helper. The build checker now
  enforces these named symbol exclusions with bounded `/usr/bin/nm` output and
  reports JPEG explicitly. The rebuilt helper passed inspection of 62,446
  symbols; the earlier helper containing the removed parsers was rejected.
  This does not prove all transitive system or other pure-Go parsers have been
  removed.
- The offline native layout was visually inspected using synthetic conversations.
  The source tripwire checks for listed frontend browser/media/shell/network
  entry points; it is a regression check, not a security audit.

[GitHub Actions passed for backend commit `1fdaef6`](https://github.com/mrichard91/keybase-osx-native-minimalist/actions/runs/36068174170).
That run includes the parser exclusions, blocking thread-reader fix and omitted
follower-list worker. The pagination fix also passed the local tests above.

Automated regression tests use no real account credentials or live chats. In a
separate, explicitly authorized owner session, an existing account was
provisioned and the native app loaded its inbox. The older installed helper still
had the dummy thread reader and displayed empty histories; installing the fixed
helper restored real text in an existing DM, multi-person group and team channel.
The displayed group and team transcripts contained only ASCII. Exactly one
approved ASCII message was sent to the owner's verified private self-chat,
read back with its confirmed message ID, and observed in the native transcript.
No test message was sent to another person or a group.

After the update, service reconnection initially timed out and recovered after
several minutes. The cause remains unproven; startup responsiveness needs further
validation. Live older-page navigation, cross-client group sends, incoming
mixed-content tests, interrupted sends and account switching remain acceptance
tasks in [ACCEPTANCE.md](ACCEPTANCE.md). The offline crypto fixtures do not
establish those server and device interactions.

The scripts use the native SwiftPM build system because this machine's default
build backend failed to initialize. Full Xcode is selected for XCTest. Synthetic
PTY tests, local socket smoke tests, and macOS signature validation require normal
macOS process access outside the development agent's restricted sandbox.
