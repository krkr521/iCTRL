# Direct file viewing from transfer notifications

Build12's runner notification opened `ictrl-app://files`, but the companion did not
route that URL to a file. Its View Files control showed progress and a Files path.

This change uses an opaque UUID to identify the selected transfer. Notification
body taps and the View File action select the same UUID; dismissals and unknown
actions do nothing. A notification arrival alone never navigates or opens the app.
Neither notification text nor payload contains filenames, paths, hashes, or tokens.

## Lifecycle

Receiving/ready notices still come from the runner. The ready action requests foreground
execution and forwards an `ictrl-app://files?id=<UUID>` URL to the companion. The runner's
existing didFinishLaunching hook now installs a small notification delegate before
XCTest setUp, covering early cold-start responses; setUp then installs the full runner
delegate for warm responses. Other early actions forward to the previous delegate.
There is no notification-driven XCTest input or private Files URL.

The companion registers its notification delegate before launch completes. Completed
save notices originate in the companion after the existing authenticated `file_saved`
acknowledgement and persistent local save record. Its body/action both route through
the same published selection, retained until the SwiftUI scene subscribes. The runner
removes its generic receiving/ready card once it observes saved; it does not post a
second saved card. The companion uses one generic passive saved card, requesting
provisional permission only if undecided (no blocking permission alert). Denied
notifications stay denied; the in-app list remains available.

For a pending transfer, selecting its UUID opens the transfer panel. The existing
receiver finishes receiving, checks SHA-256, links the document into Documents, sends
its save acknowledgement and then resolves the original selection. It never selects
the newest or a similarly named file. Unknown/expired IDs, missing local receipts,
other-recipient saves, deleted or changed files show an explicit unavailable message.
A replacement selection made while another hash/copy is awaiting is serviced locally
as soon as the old resolver unwinds, without needing a successful server poll. A
network failure reports that saving cannot yet finish; it does not open a different
file or clear any transfer state.

## Saved-file authority

The existing private `TransferReceive/<UUID>.json` retry receipt now becomes a structured
`SavedTransferDocument` after a confirmed save, containing UUID, safe basename, size and
SHA-256. Legacy string-only retry receipts remain usable for the receiver but cannot
authorize opening. At most 64 completed records are retained. Pruning metadata never
deletes a user's document. Receipt UUID must match its filename and no notification
can supply a pathname.

Every open resolves the basename within Documents, rejects escapes/symlinks and checks
regular-file type, size and SHA-256. It copies the verified file into a private preview
cache and verifies the copy again before showing or sharing it. This avoids opening a
mutated source after verification. Dismissal/back clears the preview cache; app startup
also clears leftover previews. The original saved document stays in Documents.

## User result and limits

Supported types show Quick Look directly. Unsupported types, including many IPA/ZIP
variants, show the selected filename and a Share/Open in Other App control. The system
share sheet lists eligible installed applications; SideStore presence or IPA import is
not guaranteed by iCTRL. File content is never auto-shared and no app is auto-installed.
Apple's document-browser reveal API concerns the browser hosted by an app; this feature
does not claim a public API to make Apple's standalone Files app select an arbitrary
file. The fallback path remains Files > On My iPhone > iCTRL.

## Official API evidence

- Notification delegate must be installed before launch completes:
  https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/delegate
- Response action handling:
  https://developer.apple.com/documentation/usernotifications/handling-notifications-and-notification-related-actions
- Provisional permission delivers quietly without prompting:
  https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications
- Quick Look support is checked before preview:
  https://developer.apple.com/documentation/quicklook/qlpreviewcontroller/canpreview(_:)
- SwiftUI system share control:
  https://developer.apple.com/documentation/swiftui/sharelink
- Document browser reveal is an instance method of a hosted browser:
  https://developer.apple.com/documentation/uikit/uidocumentbrowserviewcontroller/revealdocument(at:importifneeded:completion:)

## Validation

Foundation tests cover strict URL shape, exact action routing, cold-launch receipt
roundtrip, invalid names/metadata, symlink escape, replacement selections across an
await, and dismissal without reopening. Windows checks do not compile
iOS. Run `swift test --filter TransferFileRouteTests` plus the signed iOS build on macOS.
Device acceptance still must exercise warm/cold saved notification taps and custom
actions, pending-save selection, unsupported IPA share, duplicate filenames, deleted
and modified documents, denied notifications, and dismiss/ordinary delivery without
navigation. Do not publish/install another build merely to run source checks.
