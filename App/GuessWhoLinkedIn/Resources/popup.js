// Step-0 handoff spike — popup orchestration.
//
// Flow proved by this spike:
//   popup -> (probe) active content script -> popup
//   popup -> background -> sendNativeMessage -> native handler
//     -> native parks payload in App Group + opens guesswho-linkedin://handoff
//     -> the GuessWho app's scene delegate receives the URL, reads the payload
//   native ack -> background -> popup (shown below)

const api = globalThis.browser ?? globalThis.chrome;
const out = document.getElementById("out");

function show(obj, isError) {
  out.textContent = typeof obj === "string" ? obj : JSON.stringify(obj, null, 2);
  out.classList.toggle("err", !!isError);
}

async function activeTab() {
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  return tab;
}

// Probe the content script. A tab that was already open BEFORE the extension
// was enabled has no content script injected (manifest content_scripts only
// run on navigation after enable), so `tabs.sendMessage` throws "no receiver".
// In that case inject content.js on demand and retry — this is the fix for the
// `received: false` symptom (probe was undefined → native got no payload).
async function probeTab(tabId) {
  try {
    return await api.tabs.sendMessage(tabId, { type: "guesswho.probe" });
  } catch (_e) {
    // Inject the parser first, then the content script (same order as the
    // manifest), so `extractProfile` is defined when content.js runs.
    await api.scripting.executeScript({
      target: { tabId },
      files: ["parse-profile.js", "content.js"],
    });
    return await api.tabs.sendMessage(tabId, { type: "guesswho.probe" });
  }
}

document.getElementById("go").addEventListener("click", async () => {
  try {
    const tab = await activeTab();
    if (!tab || !/linkedin\.com\/in\//.test(tab.url || "")) {
      show("Not a LinkedIn profile tab (need linkedin.com/in/…).", true);
      return;
    }

    // 1) Probe the content script (inject-and-retry if not present).
    const probe = await probeTab(tab.id);
    if (!probe) {
      show({ step: "probe failed", detail: "content script returned no data" }, true);
      return;
    }

    // 2) Hand off to native (background relays to SafariWebExtensionHandler).
    const ack = await api.runtime.sendMessage({ type: "guesswho.handoff", payload: probe });

    if (!ack?.ok) {
      show({ step: "native handoff failed", error: ack?.error ?? "unknown" }, true);
      return;
    }
    if (ack.native?.received !== true) {
      show({ step: "native rejected payload", probe, nativeAck: ack.native }, true);
      return;
    }

    // 3) Wake the app from the WEB context — the native handler can't (see
    // SafariWebExtensionHandler). Navigate to the custom scheme the handler
    // returned; the app's scene delegate drains the parked payload.
    const wakeURL = ack.native?.wakeURL;
    if (wakeURL) {
      // Best-effort; if Catalyst blocks the navigation the app can still pick
      // up the parked file when next foregrounded (App-Group fallback).
      window.location.href = wakeURL;
    }
    show({ sentToGuessWho: probe, nativeAck: ack.native, openedWakeURL: wakeURL ?? null });
  } catch (e) {
    show({ error: String(e) }, true);
  }
});
