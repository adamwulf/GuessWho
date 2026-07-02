// Content script (runs in linkedin.com/in/* tabs).
//
// Answers the popup's probe with the parsed profile. The parser lives in the
// sibling `parse-profile.js`, injected alongside this file (both share the page
// execution context, so `extractProfile` is available here). If the parser is
// missing or throws, fall back to a minimal probe so the handoff still proves
// the pipe.

const api = globalThis.browser ?? globalThis.chrome;

// Step breadcrumb helper, mirroring popup.js / background.js so all three JS
// contexts read identically. Reachable only from the PAGE's Web Inspector
// console (the content script's isolated world). The pre-existing inner
// `[GuessWho] …` logs in `probe()` (photo fetch, parse result) keep their own
// format — this helper covers the listener breadcrumbs that bracket the probe.
function log(step, detail) {
  if (detail === undefined) {
    console.log("[GuessWho][content]", step);
  } else {
    console.log("[GuessWho][content]", step, detail);
  }
}

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

// Fetch the photo bytes and return a data: URL (base64). We fetch the LARGEST
// available variant (full-res, up to 800x800 for profile photos); that's tens of
// KB, still well within the native-messaging payload limit, so we pass it inline.
//
// IMPORTANT: do NOT send credentials. media.licdn.com responds with
// `Access-Control-Allow-Origin: *`, and the browser forbids combining a wildcard
// ACAO with `credentials: "include"` ("Cannot use wildcard in
// Access-Control-Allow-Origin when credentials flag is true"). These signed photo
// URLs are public — the ?t= signature is the auth — so cookies aren't needed.
// Best-effort: returns { error } on any failure.
async function fetchPhotoBytes(photoSrcset) {
  const url = largestPhotoURL(photoSrcset);
  if (!url) return { error: "no-url" };
  try {
    const res = await fetch(url, { credentials: "omit" });
    if (!res.ok) {
      console.log("[GuessWho] photo fetch HTTP", res.status, url);
      return { error: "http-" + res.status };
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
    // Surface the reason so it's visible in the (app-side) payload log even
    // without the JS console — most likely a Safari host-permission denial or a
    // CORS error on media.licdn.com.
    console.log("[GuessWho] photo fetch threw:", e);
    return { error: "threw: " + (e && e.message ? e.message : String(e)) };
  }
}

// Scroll the page to force ALL of LinkedIn's lazy-rendered sections (About,
// Experience, Education, …) into the DOM — they mount only once they enter
// the viewport. Step the viewport down the page, giving the renderer a beat
// per step, until the page bottom stops growing (or the hang-guard deadline
// is hit), then jump back to wherever the user was.
//
// Runs unconditionally on every probe, all the way to the bottom — no
// early-exit once particular sections parse. That's a deliberate product
// choice: the probe optimizes for capturing everything on the profile, not
// for the user's wait time, and a section we don't parse today may matter
// tomorrow. The deadline caps a pathological page so the handoff can never
// hang, and the user's scroll position is always restored.
//
// Uses the global `sleep` from the sibling parse-profile.js (both files share
// the content-script world; redeclaring it here would be a SyntaxError
// collision). Only reachable when the parser loaded — the call site is gated
// on `typeof extractProfile === "function"` — so `sleep` is always defined.
async function forceLazySections() {
  const startX = window.scrollX;
  const startY = window.scrollY;
  // A generous hang-guard, not a target: the pass ends once the fully-mounted
  // page stops growing (settle window below). We prefer a longer wait over an
  // incomplete parse. Profiles with an endlessly-growing tail (activity feed,
  // "People also viewed") never settle and pay the full deadline — accepted
  // by design; an early-out on diminishing growth could cut off real sections
  // on a slow connection.
  const deadline = Date.now() + 30000;
  try {
    const step = Math.max(400, Math.floor(window.innerHeight * 0.9));
    let y = step;
    let lastHeight = -1;
    let settleUntil = 0;
    while (Date.now() < deadline) {
      window.scrollTo(0, y);
      await sleep(150);
      const height = document.documentElement.scrollHeight;
      const maxY = height - window.innerHeight;
      if (y < maxY) { y += step; continue; }
      // At the bottom, but sections may still be MOUNTING (scrollHeight can
      // keep growing as modules render). Linger while the page grows; once it
      // stops, give it a short settle window before concluding everything on
      // this profile has rendered.
      if (height !== lastHeight) {
        lastHeight = height;
        settleUntil = Date.now() + 1500;
      } else if (Date.now() > settleUntil) {
        break;
      }
    }
  } finally {
    window.scrollTo(startX, startY);
  }
}

async function probe() {
  // NOTE: LinkedIn lazy-renders sections (About, Experience, …) — only what's
  // been scrolled into view is in the DOM. Parse what's there first as a
  // fallback, then scroll everything in and re-parse (below).
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

  // Lazy-section pass: everything below the fold is unrendered until it's
  // been scrolled into view, so always walk the whole page to the bottom to
  // mount every section, then re-parse. Runs whenever the parser is loaded —
  // even when the first parse fell back to the minimal probe (a mid-load page
  // is exactly when scrolling helps most; a successful re-parse supersedes
  // the fallback, which carries no field the full parse lacks). Best-effort:
  // a failed pass ships the first parse. Take the re-parse WHOLESALE, not
  // per-field: sections stay mounted once rendered (the DOM only grows during
  // the pass), and a per-field merge could pair a title and an org from
  // different sources (the atomicity rule in parse-profile.js).
  try {
    if (typeof extractProfile === "function") {
      // Inner-probe log ([GuessWho] prefix, like the photo-fetch lines) — the
      // log() helper is scoped to the listener breadcrumbs that bracket the
      // probe.
      console.log("[GuessWho] scroll pass: forcing all lazy sections", {
        about: !!result.about,
        positions: (result.experience || []).length,
      });
      await forceLazySections();
      const second = extractProfile();
      if (second) result = second;
      console.log("[GuessWho] scroll pass: done", {
        about: !!result.about,
        positions: (result.experience || []).length,
      });
    }
  } catch (e) {
    console.log("[GuessWho] scroll pass threw:", e);
  }

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
  // Best-effort; never breaks the rest of the result. On failure, attach
  // result.photoError so the reason is visible in the payload (and the app-side
  // log) without needing the JS console.
  try {
    const photo = await fetchPhotoBytes(result.photoSrcset);
    if (photo && photo.dataURL) {
      result.photo = photo;
      console.log(
        "[GuessWho] photo fetched:",
        photo.contentType,
        Math.round(photo.byteLength / 1024) + "KB"
      );
    } else {
      result.photoError = (photo && photo.error) || "unknown";
      console.log("[GuessWho] photo not fetched:", result.photoError);
    }
  } catch (e) {
    result.photoError = "caller-threw: " + (e && e.message ? e.message : String(e));
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
//
// Breadcrumbs here (read in the PAGE's Web Inspector console, not the popup's)
// are the content half of the pipe — they prove the probe ran in the tab and
// what it returned to the popup.
api.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== "guesswho.probe") return false;
  log("probe requested by popup");
  probe()
    .then((result) => {
      log("probe responding", {
        fallback: !!result._fallback,
        hasPhoto: !!result.photo,
      });
      sendResponse(result);
    })
    .catch((e) => {
      log("probe failed, sending minimal probe", { error: String(e) });
      sendResponse(minimalProbe());
    });
  return true;
});
