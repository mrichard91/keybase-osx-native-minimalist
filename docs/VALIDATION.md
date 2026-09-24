# Validation record

Checked locally on 2026-09-24 with Apple Swift 6.4, Go 1.27.1 and macOS 27 arm64.
The backend source is official Keybase revision
`f60f2ff97e35f2287375d95eafa7cad77d872072` plus the checked-in minimalist patch.

- 72 Swift tests passed: ASCII/emoji policy, API request shapes, identity/private
  conversation checks, bounded child processes, cancellation and cleanup,
  synthetic account terminals, signed-backend validation, AppKit editing, draft
  isolation, account changes, and setup/compatibility presentation.
- Account submission uses terminal Return (CR), matching the official raw
  terminal reader. A live username prompt exposed the earlier LF bug; it is
  covered by a mixed canonical/raw/secret-prompt fixture and an inert run of
  Keybase's actual terminal reader.
- 15 backend policy tests passed from freshly prepared pinned/patched source.
  They cover private ASCII posts, typed extras, internal conversation control
  messages, queued sends, optional-action bypasses, exact RPC surface, fixed
  preview policy, separate storage/Keychain names, inert constructor services,
  and text-only mobile provisioning without a temporary QR image.
- 18 existing offline Keybase crypto tests passed with the minimalist tag:
  signed/encrypted legacy message vectors, versions, remarshal, pairwise MACs,
  associated data, invalid signatures, truncation and swapped packets.
- A clean source fetch, patch application, module checksum verification and
  production backend build passed through the repository scripts.
- A final production backend started in a fresh temporary profile with
  filesystem-only test secret storage, push disabled, and its API pointed at
  closed loopback port 1. The CLI reached its service, remained logged out, and
  rejected attachment API calls. No TCP listeners appeared, shutdown exited 0,
  and the fixture was removed. No real Keybase account was used.
- The release app compiled, its hardened-runtime signature verified, and its
  packaged self-check passed for emoji resources, AppKit text input, the bundled
  backend signature/hash, and a configuration-free version subprocess.
- 20 build-inspection fixture tests passed, including malformed policy metadata,
  forbidden direct frameworks, process limits and notice provenance boundaries.
- Real macOS signing tests accepted a valid synthetic app/helper bundle and
  rejected a modified manifest, modified helper, and removal of both assets.
- The binary inspection records direct Mach-O dependencies and embedded Go module
  provenance in `build/backend/surface-report.json`. It rejects direct links to
  the listed media/browser frameworks. This does not prove all transitive system
  or pure-Go parsers have been removed.
- The offline native layout was visually inspected using synthetic conversations.
  The source tripwire checks for listed frontend browser/media/shell/network
  entry points; it is a regression check, not a security audit.

Automated tests use no real account credentials or live chats. During owner-led
acceptance, username submission was verified to advance to official existing-device
selection after the CR fix. Device provisioning and authenticated DM/group/team
interoperability remain acceptance tasks in [ACCEPTANCE.md](ACCEPTANCE.md). The
offline crypto fixtures do not establish those server and device interactions.

The scripts use the native SwiftPM build system because this machine's default
build backend failed to initialize. Full Xcode is selected for XCTest. Synthetic
PTY tests, local socket smoke tests, and macOS signature validation require normal
macOS process access outside the development agent's restricted sandbox.
