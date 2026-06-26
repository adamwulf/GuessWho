// Content script (runs in linkedin.com/in/* tabs).
//
// Answers the popup's probe with the parsed profile. The parser lives in the
// sibling `parse-profile.js`, injected alongside this file (both share the page
// execution context, so `extractProfile` is available here). If the parser is
// missing or throws, fall back to a minimal probe so the handoff still proves
// the pipe.

const api = globalThis.browser ?? globalThis.chrome;

function minimalProbe() {
  const slug = (location.pathname.match(/\/in\/([^/]+)/) || [])[1] || null;
  return {
    sourceUrl: location.href,
    slug,
    title: document.title || null,
    _fallback: true,
  };
}

function probe() {
  try {
    if (typeof extractProfile === "function") {
      const parsed = extractProfile();
      if (parsed) return parsed;
    }
  } catch (_e) {
    // fall through to the minimal probe
  }
  return minimalProbe();
}

// The popup triggers the handoff; the content script answers with the probe.
api.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== "guesswho.probe") return false;
  sendResponse(probe());
  return true;
});
