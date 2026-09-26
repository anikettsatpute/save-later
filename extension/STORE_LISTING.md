# Chrome Web Store listing — Save to Save Later

## Suggested listing copy (paste into the developer dashboard)

- **Name:** Save to Save Later
- **Short description (132 chars max):**
  Save any page, link, or selection to Save Later. AI auto-categorizes it.
- **Detailed description:**
  Save anything — YouTube, Reddit, articles, movies — and find it later.

  Right-click any page, link, selected text, image, or video and choose
  "Save to Save Later", or click the toolbar button to save the current tab
  with an optional note.

  The Save Later web app opens with your link pre-filled, fetches the title
  and preview, and AI-categorizes it into Watch / Read / Learn / Movies &
  Shows and more. Sign in with Google to sync between phone and web.

  No account needed in the extension itself — it simply hands the link to
  your Save Later library. No tracking, no analytics, no data sale.
- **Category:** Productivity
- **Language:** English
- **Website:** https://save-later-2245.web.app/
- **Support:** https://github.com/anikettsatpute/save-later/issues
- **Privacy policy URL:** host `extension/PRIVACY.md` content at a public URL
  (e.g. `https://save-later-2245.web.app/privacy.html` or the GitHub repo
  rendered page) and paste that URL in the dashboard's privacy field.

## Assets you must produce (dashboard requirements)

- [ ] Store icon 128×128 — use `extension/icons/icon-128.png`
- [ ] Screenshots 1280×800 or 640×400 (at least 1, up to 5):
      1. popup saving a tab, 2. right-click menu, 3. web app save sheet
      pre-filled, 4. inbox with the saved item
- [ ] Promo tile small 440×280 (required) + large 920×680 / marquee 1400×560
      (optional) — reuse the indigo gradient + bookmark motif from
      `assets/icon.png`
- [ ] Zip upload: `save-to-save-later-chrome-v1.0.0.zip` from project root
      (`manifest.json` at zip root — never nest inside `extension/`).
      For Edge Add-ons use the same Chrome zip. For Firefox/AMO use
      `save-to-save-later-firefox-v1.0.0.zip` (MV2 manifest at root).

## Single-purpose + permissions justification (reviewer notes)

- Single purpose: save the current page/link/selection to the user's Save
  Later library via the web app deep link.
- `contextMenus`: right-click "Save to Save Later" on page/link/selection/
  image/video.
- `activeTab`: read current tab URL/title only at save-click time to
  pre-fill. No host permissions, no content scripts, no remote code, no
  `storage`/`scripting` (removed before submission to minimize review scope).

## Publish steps

1. Pay the one-time $5 Chrome Web Store developer registration fee at
   `chrome.google.com/webstore/devconsole` (Google account required).
2. Create item → upload the zip → fill listing copy above → set visibility:
   **Private** (invite-only testers) first, then **Public** when verified.
3. Complete the privacy tab: data usage = page URL/title/selection passed to
   `save-later-2245.web.app` on user action only; no sale, no tracking.
4. Submit for review (typically a few days). Fix any policy feedback and
   re-upload with a bumped `version` in `manifest.json`.
5. Firefox (optional, separate): port to `browser.*` namespace or run under
   `about:debugging`, submit to `addons.mozilla.org` — review is manual and
   usually faster for simple extensions.

## Zero-review alternatives (no store needed)

- **Self-distribute the zip:** share `save-to-save-later-v1.0.0.zip` or the
  `extension/` folder; users install via `chrome://extensions` → Developer
  mode → Load unpacked. Works in Chrome/Edge/Brave. Downside: no auto-updates.
- **Edge Add-ons:** same zip, `partner.microsoft.com` dashboard, no fee,
  review often faster than CWS.
