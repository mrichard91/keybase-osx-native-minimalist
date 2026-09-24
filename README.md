# Keybase Minimal

A native macOS client for Keybase direct messages, multi-person groups, and team
channels. An IRC-style interface, plain ASCII text, and no rich-content rendering.

**Development software; not independently security-audited.** The app builds and
bundles a reduced official Keybase Go backend. Existing-account provisioning and
cross-client messaging still need live owner-operated acceptance before this can
be described as a proven replacement for the Electron app.

## What it includes

- Native AppKit conversation list, paginated history, unread indicators,
  in-memory drafts, and a plain-text composer.
- Official Keybase account, device-provisioning, identity-verification,
  encryption, team-key, and chat protocol implementations from a pinned revision.
- A compile-time backend policy limiting chat to private ASCII text. Attachment
  handling, link unfurls, custom emoji harvesting, commands, payments, location,
  bots, search indexing, and rich notifications are disabled. Apple audio/video
  and image-preview frameworks are absent from the built backend.
- A separate local profile and Keychain namespace. The existing Electron app is
  not required for the bundled build, and its local credentials are not copied.
- Known emoji displayed as official `:shortcodes:`; other non-ASCII content
  visibly escaped. Outgoing Unicode is rejected except known emoji converted to
  ASCII shortcodes. HTML and URLs remain inert text.
- Signed-bundle and SHA-256 checks before launching the bundled backend.

There is no Electron, WebKit, HTML/Markdown renderer, media player, attachment
viewer, clickable-link handler, plug-in system, telemetry, or third-party Swift
package in the frontend. The backend still contains official protocol parsers
and some unused Go dependencies; see [the security model](SECURITY.md).

## Build and run

Requires macOS 13+, Swift 6/Xcode 16+, Git, Python 3, and Go 1.25.5 or newer.
The checked CI toolchain is Go 1.27.1. Building the backend downloads the pinned official source and checksum-verified
Go modules. The first build takes several minutes.

```sh
bash scripts/test.sh
bash scripts/test-backend.sh
bash scripts/build-app.sh
open 'build/Keybase Minimal.app'
```

The app is produced at `build/Keybase Minimal.app`, locally ad-hoc signed with
hardened runtime. This is not a notarized distribution. See
[backend build provenance](backend/README.md) for the source lock, patch, and
manifest. Do not replace its helper or manifest with an unrelated executable.

1. Open the app and choose **Start service**. It runs the bundled foreground Go
   service without launching Electron or KBFS.
2. Choose **Account...** and log into your existing Keybase account. Provision
   this separate device through the official prompts, using an existing device
   or paper key as appropriate. Secret prompts use a masked field.
3. Choose **Connect**, select a conversation, and send plain text. Return sends;
   Shift-Return inserts a newline. Failed or uncertain sends preserve the draft
   and never retry automatically.
4. **+ Conversation** opens a DM/group from comma-separated Keybase usernames,
   or an existing channel in a team you already belong to.
5. **Earlier messages** pages backward; **Refresh** returns to the latest page.

Only the latest conversation page visibly selected in the foreground is marked
read. Account changes clear messages and drafts. Quitting stops service and
account processes started by the app and leaves pre-existing services alone.

The bundled backend fixes previews off without changing your account's shared
preview preference. Slash-prefixed text, colon-delimited times, custom-looking
shortcodes, and URLs are sent literally; they cannot invoke its removed actions.

## Deliberate limits

The app does not administer teams, manage devices, download attachments, search
all history, render disappearing messages, or expose every administrative CLI
command. Existing team membership and Keybase's account infrastructure remain
prerequisites. Account input is ASCII too; use device approval or an ASCII paper
key if your existing password contains unsupported characters.

A direct developer run (`swift run KeybaseMinimal`) has no bundled backend. It
can use only the official signed executable in `/Applications/Keybase.app` and
clearly labels this **compatibility mode**. That mode uses the full service and
shared account state, sets the shared unfurl preference to `never`, and blocks
slash commands, non-stock emoji aliases, Giphy and Keybase maps domains to avoid
known optional actions. It does not provide the bundled backend's isolation.
Packaged builds never fall back when bundled files are missing or invalid.

Read [SECURITY.md](SECURITY.md), [ASCII policy](docs/ASCII-POLICY.md),
[backend minimization](docs/BACKEND-MINIMIZATION.md), and the
[validation record](docs/VALIDATION.md). Offline tests do not establish live
provisioning or server interoperability; [acceptance steps](docs/ACCEPTANCE.md)
cover those checks.

To inspect the layout with synthetic messages and no account or network access:

```sh
open 'build/Keybase Minimal.app' --args --demo
```

This project is independent of Keybase. Project code is BSD-3-Clause. Official
backend sources, dependencies, and derived emoji data retain their own licenses.
