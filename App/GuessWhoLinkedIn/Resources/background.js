// Step-0 handoff spike — background service worker (non-persistent).
//
// Role: the ONLY place that can talk to native code. Content scripts and the
// popup send messages here; we forward them to the SafariWebExtensionHandler
// via browser.runtime.sendNativeMessage. Safari ignores the application-id
// argument and always routes to this extension's own handler.
//
// Kept deliberately trivial: this spike only proves the pipe
// (content/popup -> background -> native -> app wake), not any LinkedIn logic.

const api = globalThis.browser ?? globalThis.chrome;

// Step breadcrumbs for the background half of the pipe. Reachable only from the
// JS console (read the background page / service worker in Safari's Web
// Inspector). `[GuessWho][bg]` distinguishes these from the popup/content lines.
function log(step, detail) {
  if (detail === undefined) {
    console.log("[GuessWho][bg]", step);
  } else {
    console.log("[GuessWho][bg]", step, detail);
  }
}

api.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== "guesswho.handoff") return false;
  log("handoff message received from popup");

  // Forward a tiny payload to native. The native handler parks it in the App
  // Group and wakes the app; it replies with an ack we relay back to the popup.
  log("native: sendNativeMessage → SafariWebExtensionHandler");
  api.runtime.sendNativeMessage("application.id", { payload: message.payload }, (response) => {
    if (api.runtime.lastError) {
      // A native error here (vs. the handler returning received:false) means
      // the message never reached the handler — entitlement / process-launch
      // failure. Surface it loudly; this is a common cause of a dead handoff.
      log("native: sendNativeMessage error", { error: api.runtime.lastError.message });
      sendResponse({ ok: false, error: api.runtime.lastError.message });
      return;
    }
    log("native: ack from handler", { native: response });
    sendResponse({ ok: true, native: response });
  });

  // Returning true keeps the message channel open for the async sendResponse.
  return true;
});
