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
const goBtn = document.getElementById("go");
// The activity row (spinner + label) is visible from the popup's FIRST PAINT —
// static HTML/CSS, deliberately not created here — so the user sees motion
// before any JS (or the probe's first progress update) has run. This script
// only updates its label as the run advances and hides it when the run ends.
const loadingEl = document.getElementById("loading");
const loadingLabelEl = document.getElementById("loading-label");
const progressEl = document.getElementById("progress");
const progressListEl = document.getElementById("progress-list");

// A per-click id so the streamed progress updates from THIS probe can be told
// apart from a straggler left over from a previous click. crypto.randomUUID is
// available in the extension's popup context; fall back to a timestamp+counter
// for any runtime that lacks it.
let probeCounter = 0;
function newProbeId() {
  try {
    if (globalThis.crypto && typeof crypto.randomUUID === "function") {
      return crypto.randomUUID();
    }
  } catch (_e) { /* fall through */ }
  probeCounter += 1;
  return "probe-" + Date.now() + "-" + probeCounter;
}

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

// --- Loading progress --------------------------------------------------------
//
// The content script streams `guesswho.progress` messages as it scrolls the
// lazy sections into the DOM. Render "X/Y sections loaded" plus a per-section
// checklist so the user sees exactly which pieces we're still waiting on. The
// listener stays registered for the popup's whole lifetime and filters on the
// active probeId, so a stale straggler from a previous click can't overwrite the
// current run's display.
let activeProbeId = null;

function renderProgress(update) {
  // The section count rides the always-spinning activity row's label; the
  // checklist below details which sections are still pending.
  loadingLabelEl.textContent =
    `Loading profile… ${update.loaded}/${update.total} sections`;
  progressListEl.textContent = "";
  for (const s of update.sections || []) {
    const li = document.createElement("li");
    li.className = s.present ? "done" : "pending";
    const mark = document.createElement("span");
    mark.className = "mark";
    li.appendChild(mark);
    li.appendChild(document.createTextNode(s.label));
    progressListEl.appendChild(li);
  }
  progressEl.classList.add("active");
}

function clearProgress() {
  activeProbeId = null;
  progressEl.classList.remove("active");
  progressListEl.textContent = "";
}

api.runtime.onMessage.addListener((message) => {
  if (message?.type !== "guesswho.progress") return false;
  // Ignore progress from a probe other than the one in flight.
  if (!activeProbeId || message.probeId !== activeProbeId) return false;
  renderProgress(message);
  return false; // one-way notification, no response
});

async function activeTab() {
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  return tab;
}

// Probe the content script. A tab that was already open BEFORE the extension
// was enabled has no content script injected (manifest content_scripts only
// run on navigation after enable), so `tabs.sendMessage` throws "no receiver".
// In that case inject content.js on demand and retry — this is the fix for the
// `received: false` symptom (probe was undefined → native got no payload).
async function probeTab(tabId, probeId) {
  try {
    return await api.tabs.sendMessage(tabId, { type: "guesswho.probe", probeId });
  } catch (_e) {
    // Inject the parser first, then the content script (same order as the
    // manifest), so `extractProfile` is defined when content.js runs.
    await api.scripting.executeScript({
      target: { tabId },
      files: ["parse-profile.js", "content.js"],
    });
    return await api.tabs.sendMessage(tabId, { type: "guesswho.probe", probeId });
  }
}

// "Save anyway": the user's escape hatch out of the (unbounded) wait. We DON'T
// run the handoff here — the probe is already in flight and will resolve and
// hand off on its own. We just tell the content script to stop waiting and ship
// whatever parsed, keyed on the active probeId. The in-flight `runHandoff`
// then continues to the handoff with the (possibly partial) result.
goBtn.addEventListener("click", () => {
  if (!activeProbeId) return; // nothing in flight to interrupt
  log("save anyway: interrupting probe", { probeId: activeProbeId });
  goBtn.disabled = true; // one interrupt is enough; block re-clicks
  // Fire-and-forget one-way message; a rejection (no receiver) must not throw.
  try {
    const p = api.runtime.sendMessage({ type: "guesswho.interrupt", probeId: activeProbeId });
    if (p && typeof p.catch === "function") p.catch(() => {});
  } catch (_e) { /* content script gone — the probe will resolve regardless */ }
});

// The whole flow, run automatically when the popup opens — no initial button
// press. The "Save anyway" button only interrupts this once it's under way.
async function runHandoff() {
  log("handoff start (auto)");
  clearProgress();
  // The button starts disabled (nothing to interrupt yet) and is enabled once
  // the probe is in flight, then disabled again the moment we begin the handoff.
  goBtn.disabled = true;
  try {
    const tab = await activeTab();
    if (!tab || !/linkedin\.com\/in\//.test(tab.url || "")) {
      log("abort: not a LinkedIn profile tab", { url: tab?.url ?? null });
      show("Not a LinkedIn profile tab (need linkedin.com/in/…).", true);
      return;
    }
    log("active tab", { tabId: tab.id, url: tab.url });

    // 1) Probe the content script (inject-and-retry if not present). The probe
    // does NOT resolve until EITHER every required section (Profile, Experience,
    // About, Contact info) has mounted OR the user pressed "Save anyway" — so by
    // the time we get `probe` back below, we've either waited for everything or
    // the user chose to send what parsed. A probeId lets us correlate this run's
    // progress messages and route the interrupt to the right probe.
    const probeId = newProbeId();
    activeProbeId = probeId;
    // No show() here — the always-on spinner row already says "Loading
    // profile…"; the result pane stays hidden until there's a real outcome.
    // There's now something to interrupt — let the user press "Save anyway".
    goBtn.disabled = false;
    log("probe: requesting profile from content script", { probeId });
    const probe = await probeTab(tab.id, probeId);
    // The wait is over — lock the button (we're committing to the handoff) and
    // stop streaming progress into the checklist. The spinner keeps going with
    // an honest label: the native handoff + wake are still ahead.
    goBtn.disabled = true;
    loadingLabelEl.textContent = "Sending to GuessWho…";
    if (!probe) {
      log("probe: failed (no data)");
      show({ step: "probe failed", detail: "content script returned no data" }, true);
      return;
    }
    const readiness = probe.readiness || null;
    log("probe: got profile", {
      fallback: !!probe._fallback,
      hasPhoto: !!probe.photo,
      ready: !!(readiness && readiness.ready),
      loaded: readiness ? readiness.loaded : null,
      total: readiness ? readiness.total : null,
    });
    clearProgress();
    // If the probe resolved WITHOUT every required section — because the user
    // pressed "Save anyway", or a section never mounted — say so plainly. We
    // still proceed to the handoff with whatever parsed (that's what "Save
    // anyway" means), but the UI is honest about what didn't load.
    if (readiness && !readiness.ready) {
      const missing = (readiness.sections || [])
        .filter((s) => s.required && !s.present)
        .map((s) => s.label);
      log("probe: incomplete (interrupted or unmounted)", { missing });
      show(
        `Note: not everything finished loading (missing: ${missing.join(", ") || "unknown"}). Sending what loaded…`
      );
    }

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
      // Safari's native handler always acks a wakeURL; the Chrome background
      // worker (which shares this popup verbatim — see App/GuessWhoChrome)
      // performs the wake itself and deliberately omits it.
      log("wake: no wakeURL in ack — wake was handled (or isn't needed) upstream");
    }
    show({ sentToGuessWho: probe, nativeAck: ack.native, openedWakeURL: wakeURL ?? null });
  } catch (e) {
    log("handoff threw", { error: String(e) });
    show({ error: String(e) }, true);
  } finally {
    // Drop the progress checklist and stop the spinner. Leave the button
    // disabled — the run is over (success, abort, or throw) and this popup
    // instance won't start another; a fresh probe only happens when the popup
    // is reopened.
    clearProgress();
    loadingEl.classList.add("done");
    goBtn.disabled = true;
  }
}

// Kick off automatically as soon as the popup's DOM is ready.
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", runHandoff, { once: true });
} else {
  runHandoff();
}
