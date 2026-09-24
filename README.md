# Keybase Minimal

A native macOS client for Keybase direct messages and group conversations.
An IRC-style interface, plain ASCII text, and no rich-content rendering.

**Status: development software, not security-audited.** The native frontend
reduces rendering and interaction surface. It is not a stripped-down or
independently hardened implementation of the Keybase service, and cannot
promise protection from all RCE or account-compromise vulnerabilities.

## What it does

- Uses the **official, signed Keybase CLI and service** for accounts, device
  provisioning, identity verification, encryption, and chat transport.
- Supports existing private direct messages, multi-person groups, and team
  channels, including opening new DMs/groups and joining existing team channels.
- Uses a native AppKit window with conversation list, paginated text history,
  unread indicators, in-memory drafts, and a simple composer.
- Provides the official interactive login, signup, and logout flows in a native
  text window; credentials are sent to the official process, not a custom server.
- Displays known emoji as official `:shortcodes:`. Other non-ASCII content is
  visibly escaped. Outgoing non-ASCII text is rejected, except known emoji that
  are converted to ASCII shortcodes.
- Suppresses attachments, media, payment content, unfurls, and unsupported
  message types. Links and HTML remain inert plain text.
- Polls while open; does not run its own background agent or persist chat history.

No Electron, browser, HTML/Markdown renderer, audio/video player, image decoder,
attachment downloads, clickable links, plug-ins, telemetry, or third-party
Swift packages are included in this frontend.

## Requirements

- macOS 13 or later.
- Swift 6 / Xcode 16 or later to build.
- The official [Keybase macOS installation](https://keybase.io/download), in
  `/Applications/Keybase.app`. The Keybase Go executable is used; the Electron
  application does not have to be open.
- An existing Keybase account, or access to Keybase's official signup flow.

The current protocol integration was checked against Keybase CLI
`6.6.3-20260603142618+f60f2ff97e`. See [upstream provenance](docs/UPSTREAM.md).

## Build and run

```sh
bash scripts/test.sh
bash scripts/build-app.sh
open 'build/Keybase Minimal.app'
```

The build has no third-party Swift dependencies. The script produces a locally
ad-hoc-signed app with hardened runtime. Public binary distribution requires a
Developer ID signature and notarization; an ad-hoc signature is not notarization.
For a direct developer run, use `swift run KeybaseMinimal`.

1. Open the app and choose **Connect** if the official service is already running,
   or **Start service** to run only the official Go service.
2. Use **Account...** to log in or provision this device. Follow the official
   prompts, including device authorization or paper key as appropriate. Secrets
   are entered in a masked field whenever the process disables terminal echo.
3. Connect, select a conversation, and send plain text. Return sends;
   Shift-Return inserts a newline. A failed or uncertain send preserves the draft
   and is never retried automatically.
4. **+ Conversation** opens a DM/group from comma-separated Keybase usernames,
   or an existing channel in a team you already belong to.
5. **Earlier messages** pages backward. **Refresh** returns to the latest page.

Connecting sets the official service's **shared unfurl preference to `never`**,
and every send rechecks it. This also disables previews in other clients using
that account and can sync across devices. The preference is deliberately not restored on exit.

Only conversations explicitly selected in the foreground are marked as read.
Account changes clear this app's messages and drafts. Quitting stops a service
started by this app; it leaves a pre-existing service alone.

## Security model and deliberate limits

Read [SECURITY.md](SECURITY.md) and the [ASCII policy](docs/ASCII-POLICY.md).
The official service still parses Keybase protocol data and includes features
that this frontend does not expose. Using its full backend is a compatibility
decision, not evidence that those backend libraries have been removed or audited.

Slash commands are blocked because the official service can execute them before
sending. Custom emoji shortcodes are blocked on send because the service can
download and process their images. Only its exact stock aliases are accepted;
for example, use `:+1:` rather than `:thumbsup:`. Some colon-delimited text is
conservatively rejected because it matches Keybase's custom-emoji grammar.
Giphy and Keybase maps domains are also blocked on send: the service gives them
preview exceptions even in `never` mode. Pre-existing queued service work and
other clients remain outside this frontend's control.

Payment objects and disappearing messages are not rendered; any accompanying
plain text remains inert text. The service's payment confirmation is always false.
This version does not administer teams, manage devices, implement account reset,
download attachments, search all history, or display ephemeral content. Existing
team membership and official account infrastructure are prerequisites. Account
responses must be ASCII too; an existing non-ASCII password cannot be entered
here. Use official device approval or an ASCII paper key to provision instead.

## Validation

Automated tests use local fixtures and synthetic processes: they never log into
a real account or send a live message. Live account/provisioning and cross-client
acceptance require user-operated testing; see [the acceptance guide](docs/ACCEPTANCE.md).

To preview the visual layout without an account or network access:

```sh
open 'build/Keybase Minimal.app' --args --demo
```

This project is independent of Keybase. Code is BSD-3-Clause; the derived emoji
mapping retains Keybase's separate copyright and license notice.
