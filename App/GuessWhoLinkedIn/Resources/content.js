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

// Find the element that ACTUALLY scrolls the profile. On LinkedIn the window /
// document does NOT scroll — `document.documentElement.scrollHeight` reports
// exactly one viewport (confirmed live 2026-07: window/document/body all read
// == innerHeight while the real content lives in a nested `<main>` whose
// scrollHeight is 3×+ taller). The lazy sections mount as THAT element scrolls,
// not the window, so driving/measuring the window is a no-op and nothing ever
// crosses the real viewport. Walk up from a content anchor to the nearest
// ancestor that is genuinely scrollable (content taller than its box, with an
// overflow that scrolls), and fall back to the document scroller for layouts
// where the window really is the scroller.
function resolveScroller() {
  const anchor =
    [...document.querySelectorAll("h2")].find((h) =>
      /about|experience|education/i.test(h.textContent || "")
    ) ||
    document.querySelector("main") ||
    document.body;
  let el = anchor;
  while (el && el !== document.documentElement) {
    const cs = getComputedStyle(el);
    if (
      el.scrollHeight > el.clientHeight + 20 &&
      /(auto|scroll)/.test(cs.overflowY)
    ) {
      return el;
    }
    el = el.parentElement;
  }
  return document.scrollingElement || document.documentElement;
}

// Scroll the profile to force LinkedIn's lazy-rendered sections (About,
// Experience, Education, …) into the DOM — they mount only once they enter the
// viewport. Step the scroller down (see resolveScroller — it's a nested
// element, not the window), giving the renderer a beat per step.
//
// The loop is driven by READINESS, not by a blind "stopped growing" heuristic:
// after each scroll step we re-parse and ask `profileReadiness` whether every
// REQUIRED section (notably Experience) is now present. As soon as they are, we
// stop — we've captured everything we gate on, so there's no reason to keep the
// user waiting. If the page bottoms out and stops growing before readiness (a
// genuinely sparse profile, or a section that never mounts), we stop then too,
// rather than hang; the caller ships whatever parsed. The deadline caps a
// pathological page so the handoff can never hang, and the user's scroll
// position is always restored.
//
// `onProgress(readiness, parsed)` is invoked after each re-parse (and once at
// the start) so the caller can stream "X/Y sections loaded" to the popup while
// this runs. Returns the last readiness so the caller knows whether it bailed
// on readiness or on the deadline.
//
// Uses the global `sleep`/`profileReadiness` from the sibling parse-profile.js
// (both files share the content-script world; redeclaring `sleep` here would be
// a SyntaxError collision). Only reachable when the parser loaded — the call
// site is gated on `typeof extractProfile === "function"` — so both are defined.
async function forceLazySections(onProgress) {
  const scroller = resolveScroller();
  const startTop = scroller.scrollTop;
  const startX = window.scrollX;
  const startY = window.scrollY;

  // Re-parse and report progress; tolerate a parser throw mid-scroll (a
  // half-mounted DOM) by treating it as "nothing new this step".
  const measure = () => {
    let parsed = null;
    try { parsed = extractProfile(); } catch (_e) { parsed = null; }
    const readiness = profileReadiness(parsed || {});
    try { if (onProgress) onProgress(readiness, parsed); } catch (_e) { /* never let the UI hook break the scroll */ }
    return { parsed, readiness };
  };

  // Report the pre-scroll baseline immediately so the popup shows real progress
  // (usually identity present, experience not) the instant the pass starts.
  let last = measure();

  // A generous hang-guard, not a target: the pass ends on readiness (all
  // required sections present) or when the fully-mounted page stops growing.
  // We prefer a longer wait over an incomplete parse. Profiles with an
  // endlessly-growing tail (activity feed, "People also viewed") never settle
  // and pay the full deadline only when readiness is never reached.
  const deadline = Date.now() + 30000;
  try {
    if (last.readiness.ready) return last.readiness; // already complete — no scroll needed
    // Step by ~90% of the scroller's own viewport, not the window's — the two
    // differ when the scroller is a nested element.
    const step = Math.max(400, Math.floor(scroller.clientHeight * 0.9));
    let y = step;
    let lastHeight = -1;
    let settleUntil = 0;
    while (Date.now() < deadline) {
      scroller.scrollTop = y;
      await sleep(150);
      last = measure();
      // Primary exit: every required section is now in the DOM. Stop here — the
      // handoff has everything it gates on.
      if (last.readiness.ready) break;

      const height = scroller.scrollHeight;
      const maxY = height - scroller.clientHeight;
      // Keep climbing while there is meaningfully more to scroll OR while the
      // scroller is still growing (new sections mounting can push the bottom
      // down faster than we step). Anchoring the climb on growth — not on a
      // single maxY read — is what keeps a briefly-small measurement from
      // stranding the pass at the top (the original window-based bug).
      if (y < maxY || height > lastHeight) {
        if (height > lastHeight) {
          lastHeight = height;
          settleUntil = Date.now() + 1500;
        }
        if (y < maxY) { y += step; continue; }
      }
      // Fallback exit: at the bottom and the page has stopped growing, yet
      // we're still not "ready" (a sparse profile, or a section that never
      // mounts). Give mounting a short settle window, then stop rather than
      // hang — the caller ships whatever parsed.
      if (height <= lastHeight && Date.now() > settleUntil) {
        break;
      }
    }
  } finally {
    scroller.scrollTop = startTop;
    window.scrollTo(startX, startY);
  }
  return last.readiness;
}

// Stream a progress update back to the popup while the scroll pass runs. The
// popup opened a `browser.runtime.onMessage` listener keyed on `probeId`; this
// is a fire-and-forget one-way message (no response expected). Best-effort: a
// closed popup makes this reject, which must never break the probe.
function emitProgress(probeId, readiness) {
  if (!probeId) return;
  try {
    const p = api.runtime.sendMessage({
      type: "guesswho.progress",
      probeId,
      loaded: readiness.loaded,
      total: readiness.total,
      ready: readiness.ready,
      sections: readiness.sections,
    });
    // sendMessage returns a promise in MV3; swallow "no receiver" rejections
    // (popup closed) so an unhandled rejection never surfaces.
    if (p && typeof p.catch === "function") p.catch(() => {});
  } catch (_e) { /* popup gone — ignore */ }
}

async function probe(probeId) {
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
      // Scroll until every REQUIRED section (Experience) is in the DOM, streaming
      // "X/Y sections loaded" to the popup as it goes. The pass re-parses each
      // step; take the final re-parse WHOLESALE (below) — sections stay mounted
      // once rendered, and a per-field merge could pair a title and an org from
      // different sources (the atomicity rule in parse-profile.js).
      const finalReadiness = await forceLazySections(
        (readiness) => emitProgress(probeId, readiness)
      );
      const second = extractProfile();
      if (second) result = second;
      // Stamp the readiness onto the result so the popup's final gate (and the
      // app-side log) can see whether every required section actually loaded.
      result.readiness = finalReadiness || profileReadiness(result);
      console.log("[GuessWho] scroll pass: done", {
        about: !!result.about,
        positions: (result.experience || []).length,
        ready: result.readiness.ready,
        loaded: result.readiness.loaded,
        total: result.readiness.total,
      });
    }
  } catch (e) {
    console.log("[GuessWho] scroll pass threw:", e);
  }
  // Ensure a readiness is always present (e.g. parser missing, or the pass
  // threw before stamping) so downstream consumers never see `undefined`.
  if (!result.readiness) {
    result.readiness =
      typeof profileReadiness === "function" ? profileReadiness(result) : null;
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
  // The popup passes a probeId so it can correlate the streamed
  // `guesswho.progress` updates with this probe (and ignore stragglers from a
  // previous click). It's optional — an absent id just disables streaming.
  const probeId = message.probeId || null;
  log("probe requested by popup", { probeId });
  probe(probeId)
    .then((result) => {
      log("probe responding", {
        fallback: !!result._fallback,
        hasPhoto: !!result.photo,
        ready: !!(result.readiness && result.readiness.ready),
      });
      sendResponse(result);
    })
    .catch((e) => {
      log("probe failed, sending minimal probe", { error: String(e) });
      sendResponse(minimalProbe());
    });
  return true;
});
