// Chrome/Brave background service worker — the Chromium counterpart of
// App/GuessWhoLinkedIn/Resources/background.js (Safari).
//
// Same popup-facing contract as the Safari worker ({type: "guesswho.handoff",
// payload} in, {ok, native: {received, …}} out) so popup.js, content.js, and
// parse-profile.js are shared VERBATIM from the Safari target — build.sh
// copies them into the dist. Only the native leg differs: Chromium has no
// containing-app native handler (sendNativeMessage would need a native
// messaging host manifest installed outside the app's sandbox), so instead
// this worker:
//
//   1. WAKES the app: navigates the active tab to the per-flavor wake URL
//      (guesswho-linkedin[-debug]://handoff). LaunchServices launches or
//      foregrounds GuessWho — the browser asks "Open GuessWho?" the first
//      time; ticking "Always allow" makes later handoffs silent. External
//      protocols never actually navigate the tab, so the LinkedIn page stays.
//   2. DELIVERS the payload: POSTs it to the app's loopback-only handoff
//      listener (http://127.0.0.1:<port>/handoff, LinkedInLocalhostReceiver),
//      retrying while the app cold-launches.
//
// The app feeds the payload into the exact same match → diff → confirm → save
// pipeline the Safari handoff uses; only the transport differs. Wake fires
// BEFORE the first POST on purpose: it both cold-launches the app when needed
// and foregrounds it when already running, so the confirm sheet is visible by
// the time the payload lands.
//
// Flavor wiring (port, wake scheme) lives in config.js, GENERATED per flavor
// by build.sh — the Debug extension talks to the Xcode-installed app's
// debug port/scheme, while Release uses the production port/scheme.

import { CONFIG } from "./config.js";

const api = globalThis.browser ?? globalThis.chrome;

const ENDPOINT = `http://127.0.0.1:${CONFIG.port}/handoff`;
const WAKE_URL = `${CONFIG.wakeScheme}://handoff`;

// Retry window for the POST. Covers a cold Catalyst launch (a few seconds)
// plus the user staring at the first-run "Open GuessWho?" dialog before
// clicking. Each attempt calls an extension API (getPlatformInfo) as a
// keepalive so MV3's 30s idle reaper never fires mid-retry.
const RETRY_TOTAL_MS = 60_000;
const RETRY_INTERVAL_MS = 1_000;

// Step breadcrumbs for the background half of the pipe, mirroring the Safari
// worker. Read them via the service worker's DevTools console
// (brave://extensions → GuessWho LinkedIn → "service worker").
function log(step, detail) {
  if (detail === undefined) {
    console.log("[GuessWho][bg]", step);
  } else {
    console.log("[GuessWho][bg]", step, detail);
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Navigate the active tab to the wake URL. tabs.update with an external
// protocol hands the URL to the OS without navigating the page. Fallback: a
// throwaway tab (self-closed after the OS has taken the URL) in case some
// Chromium build rejects the update in place.
async function wakeApp() {
  log("wake: opening wake URL (web→app boundary)", { wakeURL: WAKE_URL });
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  try {
    if (tab?.id == null) throw new Error("no active tab");
    await api.tabs.update(tab.id, { url: WAKE_URL });
    log("wake: active-tab navigation requested");
  } catch (e) {
    log("wake: tabs.update failed; falling back to throwaway tab", { error: String(e) });
    try {
      const created = await api.tabs.create({ url: WAKE_URL, active: false });
      setTimeout(() => {
        try {
          const p = api.tabs.remove(created.id);
          if (p && typeof p.catch === "function") p.catch(() => {});
        } catch (_e) { /* tab already gone */ }
      }, 3000);
    } catch (e2) {
      // Both wake paths failed. Keep going: if the app is already running,
      // the POST below still delivers (the sheet just won't self-foreground).
      log("wake: throwaway-tab fallback ALSO failed", { error: String(e2) });
    }
  }
}

// One POST attempt. Distinguish "listener not up" (connection refused →
// fetch rejects → retryable) from "listener rejected us" (HTTP error status —
// wrong Origin, oversized body — where retrying can't help).
async function postPayload(payload) {
  const res = await fetch(ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ payload, stampedBy: "extension-chrome" }),
  });
  if (!res.ok) {
    const err = new Error(`app listener rejected the handoff (HTTP ${res.status})`);
    err.terminal = true;
    throw err;
  }
  return res.json();
}

async function deliverWithRetry(payload) {
  const deadline = Date.now() + RETRY_TOTAL_MS;
  let attempt = 0;
  for (;;) {
    attempt += 1;
    try {
      // Extension-API keepalive: resets the MV3 idle timer each attempt so
      // the worker survives the whole retry window.
      await api.runtime.getPlatformInfo();
      const ack = await postPayload(payload);
      log("post: delivered", { attempt, ack });
      return ack;
    } catch (e) {
      if (e.terminal || Date.now() + RETRY_INTERVAL_MS > deadline) {
        log("post: giving up", { attempt, error: String(e) });
        throw e;
      }
      if (attempt === 1 || attempt % 10 === 0) {
        log("post: app listener not reachable yet — retrying", { attempt, error: String(e) });
      }
      await sleep(RETRY_INTERVAL_MS);
    }
  }
}

api.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== "guesswho.handoff") return false;
  log("handoff message received from popup", { flavor: CONFIG.flavor, endpoint: ENDPOINT });

  (async () => {
    await wakeApp();
    const ack = await deliverWithRetry(message.payload);
    // Mirror the Safari native ack shape so the shared popup.js needs no
    // Chrome branch. No wakeURL: the wake already happened above, so the
    // popup's "navigate to wakeURL" step is intentionally skipped.
    return { ok: true, native: { received: ack?.received === true, transport: "localhost" } };
  })()
    .then((response) => sendResponse(response))
    .catch((e) => sendResponse({ ok: false, error: String(e) }));

  // Keep the message channel open for the async sendResponse. The popup
  // usually closes when the app foregrounds — the send then no-ops, and the
  // delivery above completes regardless.
  return true;
});
