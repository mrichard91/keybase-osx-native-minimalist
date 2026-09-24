# ASCII display and sending policy

All remotely supplied text must pass through `ASCIIText.sanitize` before it reaches
the interface: messages, conversation names, usernames, errors, and status fields.
Rendering must use plain text, never attributed HTML/Markdown, a web view, data
detectors, automatic links, or remote image loading. ASCII restriction alone is
not a defense against unsafe HTML rendering or passing text to a shell.

The display boundary emits only ASCII bytes 32 through 126 and line feed. CRLF
and CR normalize to line feed; a tab becomes four spaces. Every other control
and unsupported Unicode scalar becomes an explicit ASCII marker, for example
`[U+001B]`, `[U+202E]`, or `[U+00E9]`. Unicode names are not transliterated: a
Cyrillic letter that resembles a Latin letter stays visibly different. Existing
ASCII text is preserved, including literal markup and `:custom_emoji:` strings.
Escaped Unicode markers are representations; a sender can also type those
literal ASCII strings. They must not be treated as authenticated identity labels.

Known Unicode emoji are converted to canonical Keybase `:shortcodes:`. The bundled
table contains 1,875 sequences from official Keybase commit
`d559eea19a25956060f5600c7f4b8a0d976fbc8b`, including flags and joined emoji.
Emoji presentation selectors are accepted only as part of recognized emoji;
modifier tones are shown in their original order as `:skin-tone-N:` shortcodes.
For example, a medium-tone female technologist appears as
`:female-technologist::skin-tone-4:`. Unknown, future, or malformed sequences
produce explicit scalar markers for unsupported parts. No fonts, emoji pictures,
network data, JavaScript, or third-party runtime are used for this conversion.
The resource notice includes the pinned source URL, hash, and Keybase license.

Outgoing text goes through `ASCIIText.validateOutgoing`, and the transport must
send its returned string exactly. Known emoji become their ASCII shortcodes;
other non-ASCII and control characters cause validation to fail visibly. A
message must contain non-whitespace printable content and be no more than
10,000 bytes after conversion. CR and tabs normalize as described above. The
composer should explain that emoji are sent as shortcodes and should show the
returned representation before sending whenever the draft contains emoji.
The plain text composer calls `normalizeInput` for committed and marked input,
so emoji become shortcodes before AppKit renders the edit; unsupported Unicode
is rejected. Editor contents are also bounded to 10,000 bytes. Its context menu
allows only ordinary editing/copying, and Services and Quick Look are disabled.

The transport can query `isKnownEmojiShortcode` against all 1,911 exact names in
the pinned Keybase service map, including its legacy aliases. A familiar shortcode
from another chat system is not necessarily a Keybase built-in. For example,
this service snapshot recognizes `:+1:` but not `:thumbsup:`. Custom shortcode
resolution is deliberately outside the client's surface.

Display output is capped at 32,768 bytes, or a smaller caller-specified limit.
The cap includes a visible `[truncated]` marker (abbreviated for very small limits).
Truncation preserves earlier whole escape/emoji tokens. Processing uses bounded
Unicode-scalar lookahead and stops at the output cap; it does not segment entire
untrusted grapheme clusters. A missing or malformed mapping fails closed to
Unicode escaping on display and rejection when sending.

The UI restriction reduces exposed rendering code; it does not prove that the
official Keybase service, operating system, or this client is free of security
defects. The official service still receives and processes Keybase wire data.
