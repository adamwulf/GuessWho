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

// Pick the LARGEST image URL from a photoSrcset value. The value may be a
// multi-entry srcset ("url1 100w, url2 200w, … url4 800w") or a bare URL.
// LinkedIn signs each size variant separately (the ?t=… token differs per
// size and the 800 variant can even have a different filename), so we must use
// the URL the srcset actually provides for the largest descriptor — we CANNOT
// rewrite the size token in the path. Falls back to the bare URL if there are
// no "Nw" descriptors.
function largestPhotoURL(photoSrcset) {
  if (!photoSrcset) return null;
  const entries = photoSrcset.split(",").map((s) => s.trim()).filter(Boolean);
  let best = null;
  let bestW = -1;
  for (const entry of entries) {
    const parts = entry.split(/\s+/);
    const url = parts[0];
    const wMatch = (parts[1] || "").match(/^(\d+)w$/);
    const w = wMatch ? parseInt(wMatch[1], 10) : 0;
    if (w > bestW) { bestW = w; best = url; }
  }
  return best;
}

// Fetch the photo bytes IN-SESSION (so cookies/session apply — media.licdn.com
// may reject out-of-browser fetches the way the profile page does), and return
// a data: URL (base64). We fetch the LARGEST available variant (full-res, up to
// 800x800 for profile photos); that's tens of KB, still well within the
// native-messaging payload limit, so we pass it inline. Best-effort: returns
// null on any failure.
async function fetchPhotoBytes(photoSrcset) {
  const url = largestPhotoURL(photoSrcset);
  if (!url) return null;
  try {
    const res = await fetch(url, { credentials: "include" });
    if (!res.ok) {
      console.log("[GuessWho] photo fetch HTTP", res.status, url);
      return null;
    }
    const blob = await res.blob();
    const dataURL = await new Promise((resolve, reject) => {
      const r = new FileReader();
      r.onload = () => resolve(r.result);
      r.onerror = () => reject(r.error);
      r.readAsDataURL(blob);
    });
    return { dataURL, contentType: blob.type || null, byteLength: blob.size };
  } catch (e) {
    console.log("[GuessWho] photo fetch threw:", e);
    return null;
  }
}

async function probe() {
  // NOTE: LinkedIn lazy-renders sections (About, etc.) — only what's scrolled
  // into view is in the DOM. We deliberately do NOT auto-scroll to force them:
  // scrolling the page out from under the user caused flaky failures, and in a
  // normal browser window (no devtools shrinking the viewport) the sections
  // load on their own ~all the time. If About is below the fold and absent, it
  // simply comes back null — that's an accepted tradeoff.
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

  // Photo bytes: fetch the full-res variant in-session and attach as a data URL.
  // Best-effort; never breaks the rest of the result.
  try {
    const photo = await fetchPhotoBytes(result.photoSrcset);
    if (photo) {
      result.photo = photo;
      console.log(
        "[GuessWho] photo fetched:",
        photo.contentType,
        Math.round(photo.byteLength / 1024) + "KB"
      );
    }
  } catch (e) {
    console.log("[GuessWho] fetchPhotoBytes threw:", e);
  }

  // Log the full parse result to the page console. The photo data URL is huge,
  // so log the result with the photo's dataURL elided (its size is logged
  // separately above).
  const forLog = Object.assign({}, result, {
    photo: result.photo
      ? { contentType: result.photo.contentType, byteLength: result.photo.byteLength, dataURL: "<" + result.photo.byteLength + " bytes>" }
      : null,
  });
  console.log("[GuessWho] parse result:", JSON.stringify(forLog, null, 2));
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
