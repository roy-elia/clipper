# Paste 7.0.2: observed behaviour

Recorded 2026-10-25 by driving Paste live (Accessibility API, synthetic mouse events, screenshots at 2x)
and reading its preferences (`defaults export com.wiheads.paste`). Behaviour and measurements only;
nothing here is Paste's code, artwork, sound or wording to copy.

## Shelf
- Opens from the menu bar icon (left click) or ⇧⌘V. Full screen width, 332 pt tall, flush with the
  bottom of the screen the pointer is on (window frame 0,718,1680,332 on a 1680×1050 display), floating
  level 24. Rounded top corners (~24 pt), dark translucent backdrop.
- One control row, ~44 pt: suggestions button on the far left; centred group of search (icon that
  expands to a field), the current list as a selected capsule ("Clipboard" with a history glyph),
  each pinboard as a plain label with a coloured dot, and "+" to add a pinboard; "⋯" menu on the far right.
- Filter button opens a popover above the bar with three chip grids: Type (Unknown, Image, Color, File,
  Link, Text), App (every source app with its icon), Pinboard (each with its colour dot).
- Cards: square, ~234×234 pt, ~23 pt apart, corner radius ~16 pt, first card ~30 pt from the left edge.
  Header ~48 pt in the source app's colour: kind in bold (~17 pt), relative age below ("4 minutes ago",
  "5 hours ago"), and the app icon drawn oversized at the right, cropped by the header edge.
  Body: text at ~15 pt, faded out at the bottom; images fill the body edge to edge over a checkerboard.
  Footer: one centred detail ("2,875 characters", "1680 × 1050"), on a translucent pill over images.
- Selection: a ~3 pt blue ring hugging the card; it turns grey when the shelf is not key.
- Quick-paste numbers (⌘1…9) appear as small badges on the card footers (shown while the modifier is held).

## Card context menu
Paste to <front app> ↩ · Paste as Plain Text ⇧↩ · Copy ⌘C · Edit ⌘E · Rename ⌘R · Delete ⌫ ·
Pin ▸ (pinboards) · Preview (Space) · Share ▸

## ⋯ menu
About · New Text Item ⌘N · Settings… ⌘, · Help ▸ (Getting Started, Keyboard Shortcuts, Help Center,
Product Updates, Feature Request, Contact Support, Start Diagnostics) · Paste on Twitter ·
Pause Paste ▸ (Pause, 15 min, 30 min, 1 h, 3 h, 8 h) · Quit ⌘Q

## Settings (sidebar window, 648×600)
- General: Open at login; Run in background; iCloud sync (with "Synced 1 minute ago"); Sound effects.
  Paste Items: To active app / To clipboard (copy only, paste manually); Always paste as Plain Text.
  Keep History: slider Day · Week · Month · Year · Forever; Erase History… (with confirmation).
- Intelligence: Intelligent Clipboard (on-device suggestions for what you're about to paste);
  Enable MCP (AI apps connect; only approved apps get access).
- Privacy: Show During Screen Sharing; Generate Link Previews (warns it may trigger one-time links);
  Ignore confidential content; Ignore transient content; Ignore Applications list with + / −.
- Shortcuts: Activate Paste ⇧⌘V; Activate Paste Stack ⇧⌘C; Show next Pinboard ⌘→; Show previous
  Pinboard ⌘←; Quick Paste modifier (⌘ Command) + 1…9; Plain Text mode modifier (⇧ Shift);
  Reset shortcuts to default…
- Subscription (licensing; not relevant to a personal build).

## Storage, copying, drag and drop
- History lives in Core Data (store versions v1–v11, see the reverse-engineering notes); preferences in
  `com.wiheads.paste` defaults (shortcuts as JSON blobs, `selectedListIdentifier`, sync engine state).
- Spotlight: `indexingState` shows the history is indexed (7 items at the time).
- iCloud: CloudKit sync engine (`CKSyncEngineState.*`), `isSyncEnabled = 1`.
- Copy: every pasteboard change is captured with its source app; concealed and transient types are
  skipped when the Privacy toggles are on.
- Picking a card pastes into the app that was frontmost ("To active app"), or only copies it ("To clipboard").
- Cards drag out to other apps.

## Not observed live
Drag *into* Paste's shelf, Edit/Rename sheets, Share submenu contents, Help windows (not opened to avoid
side effects such as diagnostics or web pages).
