// Popup: shows current tab URL, forwards note to the service worker,
// which opens the web app as /?url=&title=&text= (Path A deep link).
const APP_URL = 'https://save-later-2245.web.app/';

async function currentTab() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab;
}

document.addEventListener('DOMContentLoaded', async () => {
  const tab = await currentTab();
  document.getElementById('url').textContent = tab?.url || '(no tab URL)';
  document.getElementById('save').addEventListener('click', async () => {
    const note = document.getElementById('note').value.trim();
    if (!tab?.url) return window.close();
    // Prefer background path (keeps one code path for URL building).
    try {
      await chrome.runtime.sendMessage({ type: 'SAVE_CURRENT_TAB', note });
    } catch (_) {
      // Service worker asleep / unreachable — open directly.
      const target =
        APP_URL +
        '?url=' + encodeURIComponent(tab.url) +
        '&title=' + encodeURIComponent(tab.title || '') +
        '&text=' + encodeURIComponent(note);
      chrome.tabs.create({ url: target });
    }
    window.close();
  });
});
