# Save to Save Later — browser extension (Path A: deep link)

No auth in the extension. It opens the web app with the link pre-filled;
the Flutter web app reads `?url=&title=&text=` and auto-opens the save
sheet (reuses `LinkParser` + AI enrich).

## Install (Chrome / Edge / Brave, developer mode)

1. Go to `chrome://extensions`, enable **Developer mode**.
2. **Load unpacked** → select this `extension/` folder.
3. Pin "Save to Save Later" to the toolbar.

## Install (Firefox, temporary)

1. Go to `about:debugging#/runtime/this-firefox` → **Load Temporary Add-on**.
2. Select any file inside `extension/` (e.g. `manifest.firefox.json` renamed
   to `manifest.json` in a copy) — or use the prebuilt
   `save-to-save-later-firefox-v1.0.0.zip` contents extracted to a folder.
3. For AMO submission use `save-to-save-later-firefox-v1.0.0.zip`
   (`manifest.json` at zip root, MV2 + `browser_specific_settings.gecko`).
   NOTE: do NOT use "Install Add-on From File" with an unsigned zip —
   release Firefox only accepts signed `.xpi` from AMO and reports anything
   else as corrupt. Use Load Temporary Add-on for local testing, or rename
   the zip to `.xpi` only after AMO signs it.

## Store zips (project root)

- `save-to-save-later-chrome-v1.0.0.zip` — Chrome/Edge (MV3, `manifest.json`
  at zip root). Upload this to the Chrome Web Store / Edge Add-ons.
- `save-to-save-later-firefox-v1.0.0.zip` — Firefox/AMO (MV2,
  `manifest.firefox.json` content as `manifest.json` at zip root).
- Never upload `save-to-save-later-v1.0.0.zip` (old, has `extension/` prefix
  inside — stores reject it as corrupt).

## Use

- Toolbar button → popup with current tab URL + optional note → **Save this tab**.
- Right-click any page / link / selected text / image / video → **Save to Save Later**.
- The web app opens at `https://save-later-2245.web.app/?url=…&title=…&text=…`
  with the save sheet open. Sign in there once; AI categorizes as usual.

## Files

- `manifest.json` — MV3, permissions: `contextMenus, activeTab`
- `background.js` — context menus + toolbar click + `SAVE_CURRENT_TAB` message
- `popup.html` / `popup.js` — popup UI, forwards note to service worker
- `icons/` — resized from `../assets/icon.png`
- `PRIVACY.md` — data-use disclosure for the Chrome Web Store listing
- `STORE_LISTING.md` — title, descriptions, screenshots checklist, review notes

## App side (already wired)

- `lib/main.dart` — `_handleWebDeepLink()` reads `Uri.base.queryParameters`
  (`url=` preferred, else first URL in `text=`/`title=`), opens `AddSheet`.
- `web/manifest.json` — `share_target` (`title`/`text`/`url` → `.`) + branding.
- `web/index.html` — title/description "Save Later".

## Test without the store

- `https://save-later-2245.web.app/?url=https://www.youtube.com/watch?v=dQw4w9WgXcQ&title=Test`
  → save sheet should open pre-filled.
