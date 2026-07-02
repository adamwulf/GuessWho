// Step-0 handoff spike — popup orchestration.
//
// Flow proved by this spike:
//   popup -> (probe) active content script -> popup
//   popup -> background -> sendNativeMessage -> native handler
//     -> native parks payload in App Group + acks the per-config wake URL
//        (guesswho-linkedin[-debug]://handoff)
//     -> the GuessWho app's scene delegate receives the URL, reads the payload
//   native ack -> background -> popup (shown below)

const api = globalThis.browser ?? globalThis.chrome;
const out = document.getElementById("out");

// Step breadcrumbs. The JS side of the handoff lives in the browser/extension
// context and can ONLY reach the JS console (it cannot write app.log), so these
// `[GuessWho][popup]` lines are how we trace the web half of the
// handoff/wake/deep-link boundary. Read them in Safari's Web Inspector for the
// popup; pair them with the app-side `app.linkedin-handoff` lines in app.log to
// see the full pipe. The most important one is the wake-navigation outcome
// below — the single point the app side can't observe.
function log(step, detail) {
  if (detail === undefined) {
    console.log("[GuessWho][popup]", step);
  } else {
    console.log("[GuessWho][popup]", step, detail);
  }
}

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
  log("handoff start");
  try {
    const tab = await activeTab();
    if (!tab || !/linkedin\.com\/in\//.test(tab.url || "")) {
      log("abort: not a LinkedIn profile tab", { url: tab?.url ?? null });
      show("Not a LinkedIn profile tab (need linkedin.com/in/…).", true);
      return;
    }
    log("active tab", { tabId: tab.id, url: tab.url });

    // 1) Probe the content script (inject-and-retry if not present).
    log("probe: requesting profile from content script");
    const probe = await probeTab(tab.id);
    if (!probe) {
      log("probe: failed (no data)");
      show({ step: "probe failed", detail: "content script returned no data" }, true);
      return;
    }
    log("probe: got profile", { fallback: !!probe._fallback, hasPhoto: !!probe.photo });

    // 2) Hand off to native (background relays to SafariWebExtensionHandler).
    log("native: sending handoff to background → native handler");
    const ack = await api.runtime.sendMessage({ type: "guesswho.handoff", payload: probe });

    if (!ack?.ok) {
      log("native: handoff failed", { error: ack?.error ?? "unknown" });
      show({ step: "native handoff failed", error: ack?.error ?? "unknown" }, true);
      return;
    }
    if (ack.native?.received !== true) {
      log("native: rejected payload", { nativeAck: ack.native });
      show({ step: "native rejected payload", probe, nativeAck: ack.native }, true);
      return;
    }
    log("native: ack received", { parked: ack.native?.parked, wakeURL: ack.native?.wakeURL ?? null });

    // 3) Wake the app from the WEB context — the native handler can't (see
    // SafariWebExtensionHandler). Navigate to the custom scheme the handler
    // returned; the app's scene delegate drains the parked payload.
    //
    // THIS is the web→app boundary: the line below is the last thing the JS
    // side does. If the app foregrounds but `app.linkedin-handoff` shows no
    // "wake URL(s) received", the navigation reached the OS but the URL was
    // dropped before the scene delegate — the exact "app just opened, nothing
    // happened" failure. We log immediately before and after so the attempt is
    // always on the record even though the navigation tears down this popup.
    const wakeURL = ack.native?.wakeURL;
    if (wakeURL) {
      log("wake: navigating to custom scheme (web→app boundary)", { wakeURL });
      try {
        // Best-effort; if the OS blocks the navigation the app can still pick
        // up the parked file when next foregrounded (App-Group fallback).
        window.location.href = wakeURL;
        log("wake: navigation requested (no throw)");
      } catch (e) {
        log("wake: navigation threw", { error: String(e) });
      }
    } else {
      log("wake: no wakeURL in native ack — cannot wake app");
    }
    show({ sentToGuessWho: probe, nativeAck: ack.native, openedWakeURL: wakeURL ?? null });
  } catch (e) {
    log("handoff threw", { error: String(e) });
    show({ error: String(e) }, true);
  }
});
