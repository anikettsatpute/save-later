// Save Later — MV3 service worker (Path A: deep link, no auth in extension).
// Opens the web app with ?url=&title=&text= ; the Flutter web app reads
// Uri.base.queryParameters and auto-opens the save sheet (LinkParser + AI).

const APP_URL = 'https://save-later-2245.web.app/';

function openSave(url, title, text) {
  const target =
    APP_URL +
    '?url=' + encodeURIComponent(url || '') +
    '&title=' + encodeURIComponent(title || '') +
    '&text=' + encodeURIComponent(text || '');
  chrome.tabs.create({ url: target });
}

// Toolbar button → save current tab. (With default_popup set, the popup
// opens instead and this is a fallback. Compat shim: Chrome MV3 exposes
// `chrome.action`, Firefox MV2 exposes `chrome.browserAction`.)
const _actionApi =
  (typeof chrome !== 'undefined' && (chrome.action || chrome.browserAction)) ||
  null;
if (_actionApi && _actionApi.onClicked) {
  _actionApi.onClicked.addListener(async (tab) => {
    if (!tab?.url || /^(chrome|edge|about|moz-extension|chrome-extension):/.test(tab.url)) return;
    openSave(tab.url, tab.title || '', '');
  });
}

// Right-click menus: page, link, selection, image, video.
chrome.runtime.onInstalled.addListener(() => {
  const contexts = ['page', 'link', 'selection', 'image', 'video'];
  for (const ctx of contexts) {
    chrome.contextMenus.create({
      id: 'save-later-' + ctx,
      title: 'Save to Save Later',
      contexts: [ctx],
    });
  }
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (!info.menuItemId.startsWith('save-later-')) return;
  const pageUrl = tab?.url || info.pageUrl || '';
  const pageTitle = tab?.title || '';
  if (info.menuItemId === 'save-later-link' && info.linkUrl) {
    openSave(info.linkUrl, pageTitle, '');
  } else if (info.menuItemId === 'save-later-selection' && info.selectionText) {
    openSave(pageUrl, pageTitle, info.selectionText);
  } else if (
    (info.menuItemId === 'save-later-image' || info.menuItemId === 'save-later-video') &&
    info.srcUrl
  ) {
    openSave(info.srcUrl, pageTitle, pageUrl);
  } else {
    openSave(info.pageUrl || pageUrl, pageTitle, '');
  }
});

// Popup (optional — same action without opening a tab first).
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg?.type === 'SAVE_CURRENT_TAB') {
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      const tab = tabs[0];
      if (tab?.url) openSave(tab.url, tab.title || '', msg.note || '');
      sendResponse({ ok: !!tab?.url });
    });
    return true;
  }
});
