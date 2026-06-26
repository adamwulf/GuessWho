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

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// LinkedIn lazy-renders sections — only what's scrolled into view exists in the
// DOM. So About (and anything below the fold) is missing on a fresh load until
// the user scrolls. Scroll through the page to force those sections to render,
// then return to the top so the page looks untouched.
async function forceLazyRender() {
  const startY = window.scrollY;
  try {
    const step = Math.max(window.innerHeight * 0.8, 400);
    const maxScroll = () =>
      Math.max(document.body.scrollHeight, document.documentElement.scrollHeight);
    let y = 0;
    // Walk down the page in steps, pausing so lazy sections can render. Bounded
    // so it never loops forever as the page grows.
    for (let i = 0; i < 25 && y < maxScroll(); i++) {
      y += step;
      window.scrollTo(0, y);
      await sleep(150);
    }
    // One settle pause at the bottom, then restore the original scroll position.
    await sleep(250);
  } finally {
    window.scrollTo(0, startY);
  }
}

async function probe() {
  // Force lazy sections (About, etc.) into the DOM before parsing.
  try {
    await forceLazyRender();
  } catch (e) {
    console.log("[GuessWho] forceLazyRender threw:", e);
  }

  let result;
  try {
    if (typeof extractProfile === "function") {
      const parsed = extractProfile();
      if (parsed) result = parsed;
    }
  } catch (e) {
    console.log("[GuessWho] extractProfile threw:", e);
  }
  if (!result) result = minimalProbe();

  // Contact info (emails/websites/profile URL) lives behind the "Contact info"
  // overlay — open it, parse it, restore the page. Async + best-effort; never
  // let it break the rest of the result.
  try {
    if (typeof extractContactInfo === "function") {
      const ci = await extractContactInfo();
      if (ci) result.contactInfo = ci;
    }
  } catch (e) {
    console.log("[GuessWho] extractContactInfo threw:", e);
  }

  // Log the full parse result to the page console so it can be copy/pasted for
  // selector debugging (alerts don't scale as the payload grows). Filter the
  // browser console on "[GuessWho]" to find it.
  console.log("[GuessWho] parse result:", JSON.stringify(result, null, 2));
  return result;
}

// The popup triggers the handoff; the content script answers with the probe.
// `probe()` is async, so resolve it then call sendResponse; returning true
// keeps the message channel open for the async reply.
api.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== "guesswho.probe") return false;
  probe().then(sendResponse).catch((e) => {
    console.log("[GuessWho] probe failed:", e);
    sendResponse(minimalProbe());
  });
  return true;
});
