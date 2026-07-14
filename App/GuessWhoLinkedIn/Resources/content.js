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

// A profile must never drive the page forever. LinkedIn changes its mobile DOM
// independently of the desktop layout; if a required section is visible to the
// user but no longer matches our parser, readiness can otherwise remain false
// indefinitely. After this bounded pass we ship the partial profile and let the
// popup report exactly which sections were missing.
const GW_LAZY_SCROLL_TIMEOUT_MS = 30_000;

// Page-JS console output is not available in an exported TestFlight log bundle.
// Stream a deliberately small DOM/readiness fingerprint through the background
// worker to the native extension logger while the probe is still in flight.
// No HTML, photo bytes, query string, or cookies are included.
const gwProbeStartedAt = new Map();
function gwClip(value, max = 160) {
  if (value == null) return null;
  const string = String(value).replace(/\s+/g, " ").trim();
  return string.length > max ? string.slice(0, max) + "…" : string;
}

function gwElementFingerprint(el) {
  if (!el) return null;
  let overflowY = null;
  try { overflowY = getComputedStyle(el).overflowY || null; } catch (_e) { /* detached element */ }
  return {
    tag: (el.tagName || "").toLowerCase() || null,
    id: gwClip(el.id, 80),
    role: gwClip(el.getAttribute && el.getAttribute("role"), 80),
    componentKey: gwClip(el.getAttribute && el.getAttribute("componentkey"), 160),
    testId: gwClip(el.getAttribute && el.getAttribute("data-testid"), 160),
    viewName: gwClip(el.getAttribute && el.getAttribute("data-view-name"), 160),
    overflowY,
    clientHeight: Number(el.clientHeight) || 0,
    scrollHeight: Number(el.scrollHeight) || 0,
  };
}

function gwExperienceDOMFingerprint() {
  const headings = [...document.querySelectorAll("h1, h2, h3")];
  const experienceHead = headings.find((h) =>
    /^experience$/i.test((h.textContent || "").trim())
  ) || null;
  const ancestors = [];
  let paragraphSampleRoot = experienceHead ? experienceHead.closest("section") : null;
  for (let node = experienceHead, depth = 0; node && depth < 8; depth++, node = node.parentElement) {
    const itemCount = node.querySelectorAll
      ? node.querySelectorAll('[componentkey^="entity-collection-item"]').length
      : 0;
    const nullStateAnchors = node.querySelectorAll
      ? [...node.querySelectorAll('[componentkey^="ProfileNullStateCardAnchor_"]')]
          .slice(0, 8)
          .map((el) => gwClip(el.getAttribute("componentkey"), 160))
      : [];
    if (!paragraphSampleRoot && itemCount > 0) paragraphSampleRoot = node;
    ancestors.push({
      depth,
      element: gwElementFingerprint(node),
      entityItemCount: itemCount,
      paragraphCount: node.querySelectorAll ? node.querySelectorAll("p").length : 0,
      listItemCount: node.querySelectorAll ? node.querySelectorAll("li").length : 0,
      nullStateAnchors,
    });
  }
  if (!paragraphSampleRoot && experienceHead) {
    for (let node = experienceHead.parentElement, depth = 0; node && depth < 8; depth++, node = node.parentElement) {
      if (node.querySelectorAll && node.querySelectorAll("p").length > 0) {
        paragraphSampleRoot = node;
        break;
      }
    }
  }
  return {
    headings: headings.slice(0, 40).map((h) => ({
      tag: (h.tagName || "").toLowerCase() || null,
      text: gwClip(h.textContent, 100),
    })),
    experienceHeadingFound: !!experienceHead,
    experienceAncestors: ancestors,
    experienceParagraphSamples: paragraphSampleRoot
      ? [...paragraphSampleRoot.querySelectorAll("p")]
          .slice(0, 30)
          .map((p) => gwClip(p.textContent, 180))
      : [],
  };
}

function gwSendDiagnostic(probeId, event, detail) {
  if (!probeId) return;
  const startedAt = gwProbeStartedAt.get(probeId) || Date.now();
  const diagnostic = {
    version: 1,
    probeId,
    event,
    elapsedMs: Math.max(0, Date.now() - startedAt),
    page: {
      host: location.hostname || null,
      path: location.pathname || null,
      userAgent: gwClip(globalThis.navigator && navigator.userAgent, 300),
      viewport: {
        width: Number(window.innerWidth) || 0,
        height: Number(window.innerHeight) || 0,
      },
    },
    detail: detail || {},
  };
  try {
    const p = api.runtime.sendMessage({
      type: "guesswho.diagnostic",
      diagnostic,
    });
    if (p && typeof p.catch === "function") p.catch(() => {});
  } catch (_e) { /* diagnostic logging must never affect the probe */ }
}

function minimalProbe() {
  const slug = (location.pathname.match(/\/(?:in|faculty|staff)\/([^/]+)/) || [])[1] || null;
  return {
    source: location.hostname === "profiles.rice.edu" ? "rice" : "linkedin",
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

// Which required sections the SCROLL pass can actually mount. Identity, About,
// and Experience render lazily as they enter the viewport, so scrolling brings
// them in. Contact info does NOT — it lives behind an overlay the scroll can't
// reach — so the scroll loop gates on this subset, and the overlay step (in
// probe()) satisfies the contact section afterward. Keep in sync with the
// section keys in parse-profile.js's profileReadiness.
const SCROLL_SECTION_KEYS = ["identity", "experience", "about"];

// Are all the scroll-mountable required sections present in this readiness?
function scrollSectionsReady(readiness) {
  const byKey = {};
  for (const s of (readiness && readiness.sections) || []) byKey[s.key] = s;
  return SCROLL_SECTION_KEYS.every((k) => !byKey[k] || byKey[k].present);
}

// --- Interrupt ("Save anyway") ----------------------------------------------
//
// The scroll pass normally waits until every scroll-mountable section is
// present. The user's immediate escape hatch is the popup's "Save anyway"
// button, which sends a `guesswho.interrupt` message keyed on the probeId. That
// listener (registered at the bottom of this file) records the id in
// `interruptedProbes`; the scroll loop checks it each iteration and bails,
// shipping whatever parsed so far. A 30-second safety bound handles a changed
// mobile DOM even if the user does nothing.
//
// `liveProbes` holds the probeIds still in flight. The interrupt listener adds
// to `interruptedProbes` ONLY for a live probe, and both Sets drop the id when
// the probe resolves. Two things fall out of that: (1) a stale interrupt from a
// previous click can't affect a fresh probe (different id), and (2) an
// interrupt that races in AFTER its probe already resolved is ignored rather
// than re-inserting an id nothing would ever clean up — so neither Set grows
// without bound.
const interruptedProbes = new Set();
const liveProbes = new Set();
function isInterrupted(probeId) {
  return !!probeId && interruptedProbes.has(probeId);
}

// Scroll the profile to force LinkedIn's lazy-rendered sections (About,
// Experience, Education, …) into the DOM — they mount only once they enter the
// viewport. Step the scroller down (see resolveScroller — it's a nested
// element, not the window) in SMALL increments, giving the renderer a beat per
// step so a section that begins loading isn't scrolled past before it finishes
// mounting.
//
// The loop is driven by READINESS, not by a blind "stopped growing" heuristic:
// after each scroll step we re-parse and ask whether every scroll-mountable
// required section (identity, Experience, About) is now present. As soon as
// they are, we stop. If the page bottoms out before everything mounted (a slow
// load, or a section whose lazy load got cancelled when an earlier fast scroll
// pushed it back out of view), we loop back to the TOP and sweep down again,
// until readiness, "Save anyway", or the 30-second safety bound. The user's
// scroll position is always restored.
//
// `onProgress(readiness, parsed)` is invoked after each re-parse (and once at
// the start) so the caller can stream "X/Y sections loaded" to the popup while
// this runs. Returns the last readiness plus the exit reason and duration.
//
// Uses the global `sleep`/`profileReadiness` from the sibling parse-profile.js
// (both files share the content-script world; redeclaring `sleep` here would be
// a SyntaxError collision). Only reachable when the parser loaded — the call
// site is gated on `typeof extractProfile === "function"` — so both are defined.
async function forceLazySections(onProgress, probeId) {
  const scroller = resolveScroller();
  const startTop = scroller.scrollTop;
  const startX = window.scrollX;
  const startY = window.scrollY;
  const passStartedAt = Date.now();
  let exitReason = "ready";
  let sweepCount = 0;
  let lastReadinessSignature = null;
  let reportedMeasureError = false;

  gwSendDiagnostic(probeId, "scroll-pass-start", {
    timeoutMs: GW_LAZY_SCROLL_TIMEOUT_MS,
    scroller: gwElementFingerprint(scroller),
    scrollerIsDocument: scroller === document.scrollingElement || scroller === document.documentElement,
    dom: gwExperienceDOMFingerprint(),
  });

  // Re-parse and report progress; tolerate a parser throw mid-scroll (a
  // half-mounted DOM) by treating it as "nothing new this step".
  const measure = () => {
    let parsed = null;
    try {
      parsed = extractProfile();
    } catch (e) {
      parsed = null;
      if (!reportedMeasureError) {
        reportedMeasureError = true;
        gwSendDiagnostic(probeId, "scroll-reparse-error", {
          error: gwClip(e && e.stack ? e.stack : e, 1000),
        });
      }
    }
    const readiness = profileReadiness(parsed || {});
    try { if (onProgress) onProgress(readiness, parsed); } catch (_e) { /* never let the UI hook break the scroll */ }
    const signature = (readiness.sections || [])
      .map((section) => `${section.key}:${section.present ? 1 : 0}`)
      .join(",");
    if (signature !== lastReadinessSignature) {
      lastReadinessSignature = signature;
      gwSendDiagnostic(probeId, "readiness-change", {
        loaded: readiness.loaded,
        total: readiness.total,
        ready: readiness.ready,
        sections: readiness.sections,
        parsedExperienceCount: parsed && Array.isArray(parsed.experience)
          ? parsed.experience.length
          : 0,
        hasAbout: !!(parsed && parsed.about),
        dom: gwExperienceDOMFingerprint(),
      });
    }
    return { parsed, readiness };
  };

  // Report the pre-scroll baseline immediately so the popup shows real progress
  // (usually identity present, experience not) the instant the pass starts.
  let last = measure();

  try {
    if (scrollSectionsReady(last.readiness)) {
      const durationMs = Date.now() - passStartedAt;
      gwSendDiagnostic(probeId, "scroll-pass-finish", {
        exitReason,
        durationMs,
        sweepCount,
        readiness: last.readiness,
      });
      return { readiness: last.readiness, exitReason, durationMs };
    }
    // Step in SMALL increments (a fraction of the scroller's viewport), keeping
    // the same per-step delay. Small steps mean a section that starts loading
    // stays in view across several steps instead of being scrolled past in one
    // jump — which is what can cancel its lazy load (the user's concern).
    const step = Math.max(150, Math.floor(scroller.clientHeight * 0.25));
    let y = 0;
    // Readiness remains the normal exit. The timeout is a safety valve for a
    // changed/unrecognized mobile DOM, while "Save anyway" is the immediate
    // user-controlled escape hatch.
    while (!isInterrupted(probeId)) {
      if (Date.now() - passStartedAt >= GW_LAZY_SCROLL_TIMEOUT_MS) {
        exitReason = "timeout";
        gwSendDiagnostic(probeId, "scroll-pass-timeout", {
          timeoutMs: GW_LAZY_SCROLL_TIMEOUT_MS,
          sweepCount,
          readiness: last.readiness,
          scroller: gwElementFingerprint(scroller),
          dom: gwExperienceDOMFingerprint(),
        });
        break;
      }
      y += step;
      const height = scroller.scrollHeight;
      const maxY = Math.max(0, height - scroller.clientHeight);
      // Past the bottom? Loop back to the top and sweep down again. Scrolling a
      // section out of view can cancel its in-flight lazy load, so a fresh
      // top→bottom sweep gives every section another chance to mount before the
      // user interrupts or the safety bound expires.
      if (y > maxY) {
        y = 0;
        sweepCount += 1;
        // Enough cadence to reveal a stuck pass without filling the log during
        // the 30-second bound.
        if (sweepCount === 1 || sweepCount % 25 === 0) {
          gwSendDiagnostic(probeId, "scroll-sweep-complete", {
            sweepCount,
            maxY,
            scroller: gwElementFingerprint(scroller),
            readiness: last.readiness,
          });
        }
      }
      scroller.scrollTop = y;
      await sleep(200);
      if (isInterrupted(probeId)) break;
      last = measure();
      // Exit: every scroll-mountable required section is now in the DOM. The
      // caller then opens the contact-info overlay for the last section.
      if (scrollSectionsReady(last.readiness)) break;
    }
    if (isInterrupted(probeId)) exitReason = "interrupted";
  } finally {
    scroller.scrollTop = startTop;
    window.scrollTo(startX, startY);
  }
  if (scrollSectionsReady(last.readiness)) exitReason = "ready";
  const durationMs = Date.now() - passStartedAt;
  gwSendDiagnostic(probeId, "scroll-pass-finish", {
    exitReason,
    durationMs,
    sweepCount,
    readiness: last.readiness,
  });
  return { readiness: last.readiness, exitReason, durationMs };
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
    //
    // NOTE for the eventual Chrome / iOS port: this relies on the promise-style
    // `browser.*` API this extension targets (Safari). Under chrome.*'s
    // callback-style sendMessage there's no returned thenable, so a closed popup
    // surfaces as "Unchecked runtime.lastError" instead — a porter should route
    // through a shim that reads `chrome.runtime.lastError` in the callback.
    if (p && typeof p.catch === "function") p.catch(() => {});
  } catch (_e) { /* popup gone — ignore */ }
}

async function probe(probeId) {
  gwSendDiagnostic(probeId, "probe-start", {
    readyState: document.readyState,
    dom: gwExperienceDOMFingerprint(),
  });
  // Rice profiles are fully server-rendered: no lazy-section scroll and no
  // contact overlay are needed. Parse once, then use the exact same in-page
  // photo-byte fetch and native handoff as LinkedIn.
  if (location.hostname === "profiles.rice.edu" && typeof extractRiceProfile === "function") {
    let rice;
    try { rice = extractRiceProfile() || minimalProbe(); }
    catch (e) {
      console.log("[GuessWho] extractRiceProfile threw:", e);
      rice = minimalProbe();
    }
    try {
      const photo = await fetchPhotoBytes(rice.photoSrcset);
      if (photo && photo.dataURL) rice.photo = photo;
      else rice.photoError = (photo && photo.error) || "unknown";
    } catch (e) {
      rice.photoError = "caller-threw: " + (e && e.message ? e.message : String(e));
    }
    const forLog = Object.assign({}, rice, {
      photo: rice.photo
        ? { contentType: rice.photo.contentType, byteLength: rice.photo.byteLength, dataURL: "<" + rice.photo.byteLength + " bytes>" }
        : null,
    });
    console.log("[GuessWho] Rice parse result:", JSON.stringify(forLog, null, 2));
    return rice;
  }

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
    gwSendDiagnostic(probeId, "initial-parse-error", { error: gwClip(e && e.stack ? e.stack : e, 1000) });
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
      // Scroll (small steps, looping top→bottom) until every
      // scroll-mountable required section — identity, Experience, About — is in
      // the DOM, streaming "X/Y sections loaded" to the popup as it goes. Save
      // anyway interrupts immediately; the 30-second safety bound ships a
      // partial result if the mobile DOM never matches. The pass re-parses each
      // step; take the final re-parse WHOLESALE (below) —
      // sections stay mounted once rendered, and a per-field merge could pair a
      // title and an org from different sources (the atomicity rule in
      // parse-profile.js).
      const scrollOutcome = await forceLazySections(
        (readiness) => emitProgress(probeId, readiness),
        probeId
      );
      const second = extractProfile();
      if (second) result = second;
      result._diagnostics = {
        version: 1,
        scrollExitReason: scrollOutcome.exitReason,
        scrollDurationMs: scrollOutcome.durationMs,
      };
      console.log("[GuessWho] scroll pass: done", {
        about: !!result.about,
        positions: (result.experience || []).length,
        interrupted: isInterrupted(probeId),
      });
    }
  } catch (e) {
    console.log("[GuessWho] scroll pass threw:", e);
    gwSendDiagnostic(probeId, "scroll-pass-error", { error: gwClip(e && e.stack ? e.stack : e, 1000) });
  }

  // Contact info (emails/websites/profile URL) lives behind the "Contact info"
  // overlay — the scroll pass can't mount it, so open it, wait for its fields to
  // load, parse it, and restore the page. This is the LAST required section; do
  // it after the scroll pass so we only pay the overlay round-trip once the rest
  // is up. Skip it entirely when the profile has NO "Contact info" link
  // (result.hasContactInfoLink === false) — there's nothing to fetch, and
  // profileReadiness already counts that section as done. Skip it if the user
  // already pressed "Save anyway" — they want whatever's parsed, now. Async +
  // best-effort; never let it break the rest of the result.
  //
  // NOTE: the interrupt is only checked at ENTRY here. Once extractContactInfo
  // is under way it is NOT abortable — a "Save anyway" pressed mid-overlay waits
  // for it to finish. That's fine: extractContactInfo is bounded (its waitFor
  // caps at ~3s and always resolves), so this can't hang the probe; it's just a
  // brief unresponsive window on the very last step.
  try {
    if (
      typeof extractContactInfo === "function" &&
      result.hasContactInfoLink !== false &&
      !isInterrupted(probeId)
    ) {
      const ci = await extractContactInfo();
      if (ci) result.contactInfo = ci;
      // Stream the updated readiness so the popup's Contact-info checkmark lights
      // up once the fields have loaded.
      emitProgress(probeId, profileReadiness(result));
    }
  } catch (e) {
    console.log("[GuessWho] extractContactInfo threw:", e);
    gwSendDiagnostic(probeId, "contact-parse-error", { error: gwClip(e && e.stack ? e.stack : e, 1000) });
  }

  // Stamp the FINAL readiness (all four required sections, including contact)
  // onto the result so the popup's gate and the app-side log see exactly what
  // loaded. Recompute here rather than reuse the scroll pass's return: the scroll
  // pass gates only on the scroll-mountable subset and knows nothing about the
  // contact overlay we just ran.
  result.readiness =
    typeof profileReadiness === "function" ? profileReadiness(result) : null;
  if (result.readiness) {
    console.log("[GuessWho] readiness after contact step", {
      ready: result.readiness.ready,
      loaded: result.readiness.loaded,
      total: result.readiness.total,
      interrupted: isInterrupted(probeId),
    });
    gwSendDiagnostic(probeId, "final-readiness", {
      readiness: result.readiness,
      parsedExperienceCount: Array.isArray(result.experience) ? result.experience.length : 0,
      hasAbout: !!result.about,
      hasContactInfo: !!result.contactInfo,
      diagnostics: result._diagnostics || null,
      dom: gwExperienceDOMFingerprint(),
    });
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
  // "Save anyway": the popup asks us to stop waiting and ship whatever parsed.
  // Fire-and-forget — record the interrupt for this probeId; the running scroll
  // loop / contact step check `isInterrupted(probeId)` and bail. No response.
  if (message?.type === "guesswho.interrupt") {
    // Only honor an interrupt for a probe that's still live. Ignoring it once
    // the probe has resolved avoids re-inserting an id into `interruptedProbes`
    // after the resolve-time cleanup already removed it (a tight race when the
    // user clicks "Save anyway" just as the probe finishes) — which would
    // otherwise leak an entry nothing cleans up.
    if (message.probeId && liveProbes.has(message.probeId)) {
      interruptedProbes.add(message.probeId);
      log("interrupt requested (save anyway)", { probeId: message.probeId });
    } else if (message.probeId) {
      log("interrupt ignored (probe not live)", { probeId: message.probeId });
    }
    return false;
  }

  if (message?.type !== "guesswho.probe") return false;
  // The popup passes a probeId so it can correlate the streamed
  // `guesswho.progress` updates with this probe (and ignore stragglers from a
  // previous click). It's optional — an absent id just disables streaming AND
  // the interrupt (there's nothing to key the "save anyway" on).
  const probeId = message.probeId || null;
  if (probeId) {
    liveProbes.add(probeId);
    gwProbeStartedAt.set(probeId, Date.now());
  }
  log("probe requested by popup", { probeId });
  probe(probeId)
    .then((result) => {
      log("probe responding", {
        fallback: !!result._fallback,
        hasPhoto: !!result.photo,
        ready: !!(result.readiness && result.readiness.ready),
        interrupted: isInterrupted(probeId),
      });
      sendResponse(result);
    })
    .catch((e) => {
      log("probe failed, sending minimal probe", { error: String(e) });
      sendResponse(minimalProbe());
    })
    // Drop this probe from both Sets once it has resolved. Removing it from
    // `liveProbes` first means an interrupt that races in after this point is
    // ignored (see the interrupt branch above), so neither Set grows without
    // bound; ids are unique per click, so nothing later can inherit a stale
    // flag either.
    .finally(() => {
      if (probeId) {
        liveProbes.delete(probeId);
        interruptedProbes.delete(probeId);
        gwProbeStartedAt.delete(probeId);
      }
    });
  return true;
});
