# Owner-operated acceptance

Automated checks never use real Keybase credentials or transmit chat messages.
Use a test account or an explicitly chosen private test conversation for these
checks. A second official client/device verifies interoperability.

1. Build and open the packaged app. Quit the Electron UI. Use Start service and
   confirm Electron and KBFS are not launched. Use Account to provision this
   separate device on your existing account with official device approval or
   a paper key. Confirm masked secret prompts and cancellation.
2. With the separate profile provisioned, check the displayed username and inbox.
   Open an existing DM and team channel. Compare current text with an official
   client; verify earlier-message pagination and unread clearing only when viewed.
3. In an explicitly chosen test DM, send an ASCII sentence and `:smile:`. Confirm
   receipt on the other official client. Reply there with plain text, emoji,
   non-ASCII letters, an attachment, HTML text, and a URL. Confirm ASCII escape /
   shortcode / omission behavior and that nothing opens or downloads.
4. Create a multi-person DM using known test usernames. Open an existing channel
   in a team you belong to. Confirm that no unintended team/channel is created.
5. Send harmless literal slash-prefixed text, colon shortcodes, and a URL in the
   test chat; verify no command, download, or preview action occurs. Try control
   characters and unsupported Unicode; verify rejection without a send. Test clipboard HTML/file input and
   file drops: only bounded plain text should ever enter the composer.
6. Disconnect the network during send. Confirm the draft remains and that there
   is no automatic retry. Check the official client before retrying manually.
7. On a test device/account, use Account to exercise official login and device
   provisioning, including paper-key or existing-device authorization. Confirm
   secret prompts use masked input and closing the window cancels the process.
   Signup depends on Keybase's current server availability and requirements.
8. Switch the bundled backend to another test account using Account. Refresh this
   app and confirm that old messages/drafts clear and reconnection is required.
9. Quit the app. An app-started service should stop; a pre-existing service should
   remain. Restart: no plaintext app history/drafts should be restored.

Record macOS, Keybase version, test date and outcomes. Do not store credentials
or private chat contents in the repository. Until these checks pass, the project
should be described as a development build rather than a proven daily replacement.
