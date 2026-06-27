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

api.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== "guesswho.handoff") return false;

  // Forward a tiny payload to native. The native handler parks it in the App
  // Group and wakes the app; it replies with an ack we relay back to the popup.
  api.runtime.sendNativeMessage("application.id", { payload: message.payload }, (response) => {
    if (api.runtime.lastError) {
      sendResponse({ ok: false, error: api.runtime.lastError.message });
      return;
    }
    sendResponse({ ok: true, native: response });
  });

  // Returning true keeps the message channel open for the async sendResponse.
  return true;
});
