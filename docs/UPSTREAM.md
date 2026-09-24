# Official Keybase components

The packaged app builds and bundles the official Keybase Go source at the full
revision in `backend/upstream.json`, with the reviewed local
`backend/patches/minimalist.patch`. It preserves official cryptography and account
flows, and does not embed Electron. See [backend build instructions](../backend/README.md)
and [the policy changes](BACKEND-MINIMIZATION.md).

An unpackaged developer run may use the installed official signed CLI in clearly
identified compatibility mode. The original-service behavior below documents why
that mode needs additional text restrictions.

- [Official client repository](https://github.com/keybase/client)
- [Keybase Go client at tested version f60f2ff97e](https://github.com/keybase/client/tree/f60f2ff97e/go)
- [Chat API command and help](https://github.com/keybase/client/blob/f60f2ff97e/go/client/cmd_chat_api.go)
- [Chat API handler](https://github.com/keybase/client/blob/f60f2ff97e/go/client/chat_api_handler.go)
- [Service chat handling](https://github.com/keybase/client/blob/f60f2ff97e/go/chat/server.go)

Local inspection on 2026-09-24 found official CLI version
`6.6.3-20260603142618+f60f2ff97e`, code-signing identifier `keybase`, and team
identifier `99229SGT5K`. Runtime signature validation authenticates the installed
official signer, not a fixed version. Users remain responsible for installing
official supported updates. Arbitrary source-built CLI paths are not accepted. The packaged helper is
accepted only through the signed-bundle manifest and hash-validation path.

The offline emoji map has its own pinned upstream revision and full license
notice in `Sources/MinimalCore/Resources`; its data is bundled, never fetched
while reading a message.

The emoji source at the tested CLI revision has the same Git blob as the bundled
map's revision: `86cb2bf3fa9481ce2e69c85f0bd93b194097e4a6`. Both the stock alias
allowlist and Unicode mapping therefore match this tested version. Behavior and
the built-in alias list must be reviewed when changing the supported service.

## Verified source API contract

The protocol investigation used the installed CLI's `chat api --help`, `login
--help`, and `whoami --help`, plus the immutable source revision
[`f60f2ff97e35f2287375d95eafa7cad77d872072`](https://github.com/keybase/client/commit/f60f2ff97e35f2287375d95eafa7cad77d872072).
The tests use synthetic replies derived from these definitions. They do not
contain account data or prove live-server compatibility.

| Operation | Contract and source |
| --- | --- |
| Inbox | `list`, options `topic_type: "CHAT"`, `fail_offline: true`; optional `conversation_id` filters one conversation. [Handler](https://github.com/keybase/client/blob/f60f2ff97e35f2287375d95eafa7cad77d872072/go/client/chat_svc_handler.go#L74) |
| Thread | `read`, options `conversation_id`, `peek: true`, `fail_offline: true`, `pagination: {num: 100, next?: "base64"}`. `peek` avoids changing read state. [Handler](https://github.com/keybase/client/blob/f60f2ff97e35f2287375d95eafa7cad77d872072/go/client/chat_svc_handler.go#L622) |
| Read state | `mark`, options `conversation_id` and integer `message_id`; called only after displaying the current page in the active window. [Handler](https://github.com/keybase/client/blob/f60f2ff97e35f2287375d95eafa7cad77d872072/go/client/chat_svc_handler.go#L1062) |
| Send | `send`, options `conversation_id`, `message: {body: "ASCII"}`, `nonblock: false`, `confirm_lumen_send: false`. [Options](https://github.com/keybase/client/blob/f60f2ff97e35f2287375d95eafa7cad77d872072/go/client/chat_api_handler.go#L193) |
| Direct/group creation | `newconv` with private `CHAT`, `members_type: "impteamnative"`, comma-separated Keybase usernames. It returns only an ID, so the app fetches the corresponding inbox record. [Handler](https://github.com/keybase/client/blob/f60f2ff97e35f2287375d95eafa7cad77d872072/go/client/chat_svc_handler.go#L1220) |
| Existing team channel | `listconvsonname`, options `name`, `members_type: "team"`, `topic_type: "CHAT"`, then `join` by the selected existing ID. No new team/channel request is made. [Handlers](https://github.com/keybase/client/blob/f60f2ff97e35f2287375d95eafa7cad77d872072/go/client/chat_svc_handler.go#L121) |
| Preview preference | `getunfurlsettings` returns `{mode, whitelist}`; `setunfurlsettings` with `mode: "never"` returns the Boolean `true`. The app verifies the saved value before proceeding. [Handlers](https://github.com/keybase/client/blob/f60f2ff97e35f2287375d95eafa7cad77d872072/go/client/chat_svc_handler.go#L259) |

The [generated API models](https://github.com/keybase/client/blob/f60f2ff97e35f2287375d95eafa7cad77d872072/go/protocol/chat1/api.go#L367)
define `result.messages[]` as `{msg?: {...}, error?: "..."}`. A message includes
its conversation ID, channel, integer ID, sender, timestamp, and `content.type`.
Only `content.text.body` is displayed as message text. Edits, deletions, system
events, and unsupported content receive fixed notices; the service is responsible
for resolving current message versions. Replies with identity failures or offline
status are rejected. The service explicitly normalizes an empty thread to `[]`,
while its inbox conversation slice can encode as `null`. `unread` in a conversation
is a non-optional JSON Boolean.

## Full-service behavior and compatibility restrictions

The official `PostLocal` path is not a passive text transport. These restrictions
are intentional defenses against extra processing observed in the pinned source:

- **Slash commands:** [server.go](https://github.com/keybase/client/blob/f60f2ff97e35f2287375d95eafa7cad77d872072/go/chat/server.go#L784)
  executes built-in commands before sending. The app rejects messages whose first
  non-whitespace character is `/`.
- **Payments:** [runStellarSendUI](https://github.com/keybase/client/blob/f60f2ff97e35f2287375d95eafa7cad77d872072/go/chat/server.go#L860)
  parses and describes in-chat payments before asking the CLI UI to approve them.
  The API's [ChatAPIUI](https://github.com/keybase/client/blob/f60f2ff97e35f2287375d95eafa7cad77d872072/go/client/chat_api_ui.go#L35)
  returns false with `confirm_lumen_send: false`, preventing payment execution.
  Parsing code still exists in the official service; this frontend does not remove it.
- **Custom emoji:** [sender.go](https://github.com/keybase/client/blob/f60f2ff97e35f2287375d95eafa7cad77d872072/go/chat/sender.go#L593)
  harvests emoji aliases from text. Cross-team aliases can cause
  [attachment download and re-upload](https://github.com/keybase/client/blob/f60f2ff97e35f2287375d95eafa7cad77d872072/go/chat/emojisource.go#L830).
  The app uses the [official parsing grammar](https://github.com/keybase/client/blob/f60f2ff97e35f2287375d95eafa7cad77d872072/go/chat/globals/globals.go#L15)
  and permits only bundled stock names. Stock-name collisions are
  [suffixed by the service](https://github.com/keybase/client/blob/f60f2ff97e35f2287375d95eafa7cad77d872072/go/chat/emojisource.go#L623),
  and the suffixed aliases are rejected. The broad official grammar means some
  ordinary colon-delimited text, such as `18:00:00`, is conservatively rejected.
- **Preview exceptions:** `never` still permits automatic Giphy and Keybase maps
  previews in [extractor.go](https://github.com/keybase/client/blob/f60f2ff97e35f2287375d95eafa7cad77d872072/go/chat/unfurl/extractor.go#L122).
  The app additionally rejects text containing `giphy.com` or `keybasemaps`,
  including encoded forms. Other links remain plain text. The
  [automatic domains](https://github.com/keybase/client/blob/f60f2ff97e35f2287375d95eafa7cad77d872072/go/chat/unfurl/extractor.go#L62)
  and [maps constant](https://github.com/keybase/client/blob/f60f2ff97e35f2287375d95eafa7cad77d872072/go/chat/types/types.go#L39)
  must be reviewed again when upstream behavior changes.

## Full-service background surface

The official service starts background chat modules including indexing, coin
flips, live-location tracking, bot commands, and loaders for logged-in users.
The native app does not invoke those features, but they remain in the trusted
service binary. [Startup code](https://github.com/keybase/client/blob/f60f2ff97e35f2287375d95eafa7cad77d872072/go/service/main.go#L415)

The app explicitly starts only the foreground `keybase service` command. It
passes `--no-auto-fork`, `--no-debug`, and `--app-start-mode minimalist` for the
documented non-GUI startup intent. The
[CLI option declaration](https://github.com/keybase/client/blob/f60f2ff97e35f2287375d95eafa7cad77d872072/go/libcmdline/cmdline.go)
describes values other than `service` as disabling UI autostart; this is not a
switch that removes the service's background modules.

Preview settings are stored in
[user-conversation-backed storage](https://github.com/keybase/client/blob/f60f2ff97e35f2287375d95eafa7cad77d872072/go/chat/unfurl/settings.go#L108),
so changing them is a shared account preference, not an app-local setting. Another
client/device can change that state between verification and sending. Setting
`never` does not cancel previously queued unfurl tasks: the
[retry path](https://github.com/keybase/client/blob/f60f2ff97e35f2287375d95eafa7cad77d872072/go/chat/unfurl/unfurler.go#L149)
can run an already saved task directly. This frontend neither starts nor cancels
those existing jobs. It does not guarantee that the entire official service
cannot process or download media.

The JSON API does not provide an atomic per-message switch disabling all command,
emoji, payment, and preview processing. The bundled backend supplies a compile-time policy and isolated namespace to
remove these optional execution paths. It still needs independent review and
live compatibility acceptance; the established identity and encryption
implementation is retained.
