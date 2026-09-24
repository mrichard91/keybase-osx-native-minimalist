# Validation record

Validated locally on 2026-09-24 with Apple Swift 6.4 and macOS 27 (arm64),
against official Keybase CLI/service `6.6.3-20260603142618+f60f2ff97e`.

- 37 automated tests passed: ASCII/emoji boundaries, source-derived API fixtures,
  identity failures, private conversations, send guards, bounded processes,
  cancellation, terminal control filtering, and a synthetic interactive PTY.
- Release application compiled and its ad-hoc hardened-runtime signature verified.
- Packaged self-check passed: resource lookup, native AppKit committed/marked text
  normalization, exact official emoji alias data, installed Keybase signature,
  and bounded subprocess execution. Only the CLI version was queried.
- Offline preview opened and the native conversation/sidebar/composer layout was
  visually inspected. No real messages appeared in that preview.
- Static source tripwire found no listed browser/media frameworks, shell launch,
  direct networking, or external URL-opening entry points. This is a regression
  check, not a security audit or whole-program proof.

No real account login/logout, service startup, inbox read, or chat send was used
for these checks. Live provisioning, send/receive, group interoperability, and
account switching remain owner-operated acceptance tasks in [ACCEPTANCE.md](ACCEPTANCE.md).

The build/test scripts use the native SwiftPM build system because this machine's
default build backend failed to initialize. Full Xcode is selected per command
for XCTest. The PTY integration fixture and macOS signature validation require
normal macOS process access, outside the development agent's restricted sandbox.
