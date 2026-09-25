# Security model

## Aim and trust boundary

Reduce the code and interactions reachable from untrusted messages while keeping
Keybase's official identity and cryptographic protocol. This is new, unaudited
code. ASCII rendering does not guarantee RCE immunity or prevent every account
compromise.

The native app trusts macOS and a backend built from the pinned official source
plus the checked-in minimalist patch. It verifies the signed app, its current
code identity, the sealed manifest, the helper signature, and the helper's
SHA-256 before launch. A signed bundle marker prevents fallback if its helper or
manifest disappears. No PATH lookup or user-configurable executable is exposed.
A locally ad-hoc-signed build establishes integrity, not a publisher identity;
public distribution still needs Developer ID signing and notarization.

The backend uses separate `keybase-minimalist` configuration, cache, runtime,
socket, and Keychain service names. Its device must be provisioned through the
official account flow. It does not copy the original application's secrets.
The app is not App Sandbox isolated; hardened runtime alone is not a sandbox.

## Enforced boundaries

- Structured subprocess arguments and JSON stdin; no shell invocation with user
  content. Bounded output, timeouts, cancellation, process-group ownership, and
  a constrained child environment. App exit prevents new child launches.
- Private CHAT conversations and identity checks before sends. Unexpected
  identities, malformed replies, and uncertain send results fail closed.
- Plain AppKit text only, with rich paste, file drops, link handling, text-system
  data detection, and Writing Tools disabled. External displayed strings pass
  through the ASCII sanitizer. Outbound text has a separate strict limit.
- Unsupported incoming content receives fixed notices. The UI requests no
  attachment downloads and hides ephemeral content. No message logs or on-disk
  frontend chat/draft database are created.
- A compile-time backend policy rejects non-text user posts and typed rich
  payloads before service callbacks. The lower sender also checks the verified
  conversation and queued messages. Necessary internal conversation-control
  messages remain available.
- The backend bypasses slash-command handling, payment parsing, emoji harvesting,
  reply/mention decoration, unfurls, live location and rich notifications. These
  strings remain inert text. RPC registration excludes attachment, wallet,
  filesystem, search, bot and other optional interfaces.
- Optional background components use inert implementations. Previews always
  report NEVER and cannot be enabled through settings. This does not write the
  account's shared preview preference.
- The optional follower-list tracker loader is omitted from service construction
  and cannot start through the login hook. Required identity and key checks remain.
- Thread reads use the official blocking loader and verified conversation source,
  preserving pagination, read-marking requests and source errors. The optional
  predecoded-remote shortcut and nonblocking rich UI loader are disabled.
- Native media preview implementations and image-processing functions for custom
  emoji, GIF conversion, audio waveforms, avatars, maps and coin-flip graphics are
  excluded from the minimalist build. Their substitutes never read image input
  or generate an image. GIF, PNG, TIFF and CR2 decoder packages
  and initialization symbols are absent from the rebuilt backend.
- Password and paper-key responses use the official CLI's interactive terminal
  flow. Account responses always use a masked input field, and terminal echo is
  suppressed. App and CLI process memory are not guaranteed to be securely erased.

## Remaining surface and acceptance

The backend still parses official encrypted protocol and typed message metadata,
including metadata for unsupported attachment kinds, to preserve authentication
and message-chain verification. Not every unused pure-Go dependency has been
removed. Official networking, caches, key storage, and key-maintenance operations
remain. The standard-library JPEG decoder is still linked through the official
OpenPGP packet package's photo-encoding helper; that dependency has not been
modified. Review of the selected production source found no current caller of the
photo helper or image/JPEG decoders in retained application or third-party code.
OpenPGP user attributes remain opaque bytes during parsing and serialization.
This is not a proof that the linked decoder is unreachable under every condition
or future change. Parser exclusions do not change signed-packet parsing or
cryptography. The local RPC account interfaces retain official login/provisioning
behavior through narrow entry points; their internal engines remain substantial. See
[backend minimization](docs/BACKEND-MINIMIZATION.md) for exact changes and limits.

This design does not protect against an already-compromised same-user process,
hostile OS, stolen recovery secret, malicious trusted update, or vulnerabilities
in retained code. OS swap, user-copied clipboard text and crash handling are
outside the frontend's in-memory history guarantee.

The app checks the account around reads and before sends and clears stale state
when it changes. Separate CLI requests have no atomic expected-account guard;
do not switch that backend's account during an in-flight send. Separation from
the original service reduces accidental account interference but is not a
security boundary against malicious software running as the same user.

Owner-operated checks have verified provisioning, DM/group/team history reads
and one private self-message. Broader cross-client sends, mixed-content handling,
failure recovery and account switching remain acceptance requirements. Source
tests cannot substitute for these server/device interactions. Before broad use: independent review, dependency
review, signed/notarized releases and a maintained upstream update process.

## Developer compatibility mode

An unpackaged developer run can use the installed full official CLI, validated
against Keybase's code-signing identity. That mode retains the full service's
media/background features and shared account state. The UI distinguishes it.
It rechecks the shared `never` preview preference before sends and blocks slash
commands, custom emoji names, and known preview-exception domains. Another client
can change that setting and pre-existing queued work can still run; those
restrictions are not equivalent to the bundled policy. A packaged build with
missing or invalid backend resources never downgrades into compatibility mode.

## Reporting

Report reproducible non-sensitive defects through repository issues. Do not post
private chats, credentials, keys, tokens, or exploitable vulnerability details
publicly. Coordinate a private disclosure channel with the repository owner
before sending sensitive reports.
