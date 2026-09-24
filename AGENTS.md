# Project rules

This is a security-sensitive, native macOS Keybase chat client.

- Keep the UI in AppKit and use plain text. No WebKit, HTML/Markdown renderers, media decoding, rich paste, URL opening, attachment downloads, analytics, plug-ins, or third-party Swift dependencies.
- Keep identity, provisioning, protocol and cryptography in official Keybase code. The bundled minimalist backend must be built from the pinned official source plus the reviewed local patch, use an isolated storage/Keychain namespace, and pass signed-bundle/hash validation. The compatibility path accepts only the official signed CLI. Do not invent crypto or handle account keys in the chat UI.
- Never launch a shell with untrusted data. Use fixed executable paths, validated signatures and structured arguments/stdin.
- Apply the ASCII boundary to all external strings shown by the UI and reject non-ASCII outbound payloads except known emoji converted to colon shortcodes.
- Verify previews are disabled before sending. The bundled backend must fix this policy without shared preference writes; compatibility mode sets and verifies the official shared setting. Fail closed on errors.
- Keep messages and drafts in memory. Do not log messages, passwords, paper keys, tokens or entire API responses.
- Tests must cover security boundaries, API request shapes, malformed messages, process limits and account input handling.
- Do not claim this is audited or immune to RCE. Document the official service's remaining attack surface.
- Never send a live chat or change a real account during tests without explicit user authorization for that test.
