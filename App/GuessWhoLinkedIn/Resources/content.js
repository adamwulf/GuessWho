// Step-0 handoff spike — content script (runs in linkedin.com/in/* tabs).
//
// This spike does NOT do real parsing. It grabs one trivially-stable signal
// (the page title + profile slug) so the handoff payload carries something
// real, proving the content -> background path works on an actual tab. The
// full semantic-anchor parser lands in a later build step.

const api = globalThis.browser ?? globalThis.chrome;

function minimalProbe() {
  const slug = (location.pathname.match(/\/in\/([^/]+)/) || [])[1] || null;
  return {
    sourceUrl: location.href,
    slug,
    title: document.title || null,
  };
}

// The popup triggers the handoff; the content script answers with the probe.
api.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== "guesswho.probe") return false;
  sendResponse(minimalProbe());
  return true;
});
