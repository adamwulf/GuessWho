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

document.getElementById("go").addEventListener("click", async () => {
  try {
    const tab = await activeTab();
    if (!tab || !/linkedin\.com\/in\//.test(tab.url || "")) {
      show("Not a LinkedIn profile tab (need linkedin.com/in/…).", true);
      return;
    }

    // 1) Probe the content script for the minimal real signal.
    const probe = await api.tabs.sendMessage(tab.id, { type: "guesswho.probe" });

    // 2) Hand off to native (background relays to SafariWebExtensionHandler).
    const ack = await api.runtime.sendMessage({ type: "guesswho.handoff", payload: probe });

    if (!ack?.ok) {
      show({ step: "native handoff failed", error: ack?.error ?? "unknown" }, true);
      return;
    }
    show({ sentToGuessWho: probe, nativeAck: ack.native });
  } catch (e) {
    show({ error: String(e) }, true);
  }
});
