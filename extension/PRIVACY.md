# Privacy Policy — Save to Save Later (browser extension v1.0.0)

Last updated: 2026-09-20

## What the extension does
When you click "Save to Save Later" (toolbar button, popup, or right-click
menu), the extension opens your Save Later web app at
`https://save-later-2245.web.app/` with the page URL, tab title, and any
selected text passed as URL parameters (`?url=&title=&text=`). The web app
then saves the link to your library.

## Data the extension handles
- **Page URL, tab title, selected text / note** — passed to the Save Later
  web app only when you explicitly invoke a save action. Nothing is sent
  anywhere else.
- **No accounts, no sign-in, no analytics, no tracking.** The extension has
  no backend, sets no cookies, and makes no network requests of its own —
  it only opens the Save Later web app URL.
- **No data sale or sharing.** The extension does not sell, share, or
  disclose your data to third parties.

## Data stored by the extension
None. The extension uses no persistent storage (`chrome.storage` is not
used). Your saved items live in the Save Later web app under your Google
account (Firebase Auth + Firestore, scoped to your user id), governed by
that app's sign-in and rules — not by this extension.

## Permissions and why
- `contextMenus` — adds the "Save to Save Later" right-click menu.
- `activeTab` — reads the current tab's URL/title only when you click save,
  to pre-fill the save sheet.

## Contact
Issues: https://github.com/anikettsatpute/save-later/issues
