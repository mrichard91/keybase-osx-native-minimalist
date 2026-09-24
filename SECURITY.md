# Security model

## Aim and trust boundary

Reduce the client surface exposed to untrusted messages while preserving the
official Keybase identity and cryptographic protocol. This code is new and has
not been independently audited. No claim of RCE immunity or prevention of every
account takeover is made.

The native app trusts macOS, the installed signed Keybase executable, and the
official Keybase service. The service retains its own protocol parsers, network
connections, local caches, key storage, and background features. The frontend is
not App Sandbox isolated: it needs access to the user's Keybase socket and to
launch the official executable. Hardened runtime alone is not a sandbox.

## Enforced by this frontend

- Only pinned-identity, validly signed Keybase executable paths are accepted.
  PATH lookup and user-supplied executable paths are not exposed.
- Process arguments are structured; chat bodies travel as JSON on stdin.
  No shell interpolation or command construction from chat content.
- Subprocess output and running time are bounded. The environment is constrained.
- Chat API operations are a small allowlist. Private CHAT conversations only.
  Identity verification failures stop the operation rather than being hidden.
- All remote display text passes through the ASCII sanitizer. Known emoji map
  to colon shortcodes; other Unicode and control characters become visible
  escapes. Outbound text must satisfy a separate strict policy.
- Plain AppKit text only. Rich paste and file drops are disabled. No URL opening,
  HTML/Markdown interpretation, media decoding, notification previews or previews.
- The frontend does not request downloads of attachment/media/custom emoji payloads. Unsupported message
  kinds produce fixed notices. Ephemeral messages are hidden to avoid preserving
  disappearing content across polls.
- Slash commands and payment actions are not allowed. The official service's
  unfurl setting must be `never` before sends. Errors fail closed; uncertain sends
  never trigger automatic retries.
- Password/paper-key input uses the official CLI's PTY flow. The UI does not
  persist or log secrets. Native strings and OS process memory are not guaranteed
  to be securely erased; the OS and official CLI remain in scope.
- Message history and drafts exist only in app memory. Keybase service storage,
  OS swap, clipboard contents explicitly copied by the user, and system crash
  handling are outside that guarantee.

## Limits requiring further work

Removing frontend renderers does not remove unused code from the official Go
service or prove that its parsers are safe. Its own unfurl/background behaviors
must be reviewed independently; the shared setting can also be changed by another
client. There is no transactional per-message unfurl disable in the JSON API.

An already-compromised same-user process, hostile OS, stolen recovery secret,
malicious trusted update or official backend vulnerability is not neutralized
by ASCII rendering. ASCII itself can contain malicious instructions or misleading
URLs; it is not a guarantee of trustworthy content.

The official service's `never` unfurl mode still exempts Giphy and Keybase maps
links. Outgoing special domains and non-stock emoji aliases are rejected to
avoid those known paths. Previously queued unfurls can still run, and another
client can change the shared preference between this app's check and send.
The daemon also starts search, bot, coinflip and location components. None of
these backend libraries or tasks has been removed by this frontend. See the
pinned source evidence in [UPSTREAM.md](docs/UPSTREAM.md).

The app checks the active account around reads and before sends, clears state
when it observes a change, and validates conversation identity before sending.
The CLI API provides no atomic expected-account guard spanning separate calls;
avoid switching the shared service's account while this app is sending.

The account UI carries the official interactive flow but does not claim to
implement every administrative CLI feature. Live device provisioning, account
creation and messaging must be verified by the account owner before relying on
this as a daily client. Source tests cannot substitute for that acceptance.

Before broader deployment: independent review of process and PTY boundaries,
live compatibility testing, dependency review of the official backend, signed
and notarized releases, and a maintained update process are required.

## Reporting

Report reproducible non-sensitive defects through repository issues. Do not post
private messages, account keys, paper keys, passwords, tokens, or exploitable
vulnerability details publicly. Coordinate a private disclosure channel with the
repository owner before sending sensitive reports.
