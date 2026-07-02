// LinkedIn profile parser — runs in the content script's page context.
//
// DESIGN: anchor on STABLE SEMANTIC SIGNALS, never on LinkedIn's class names.
// Confirmed from a real profile (2026-06): the logged-in DOM has NO JSON-LD and
// NO OpenGraph meta tags, and every class is an obfuscated rotating token
// (e.g. "_18045a1c f2813a6b ccd16393 ae68a123"). So we use: the page <title>,
// the profile photo's `alt` text, the top-card structural order, and the
// "About" <h2> landmark. Every field is best-effort and returns null on failure
// — one field breaking must never break the others.
//
// CAVEAT (self-view vs. other-view): a profile viewed while logged in as
// YOURSELF renders Edit buttons and a slightly different top card than viewing
// SOMEONE ELSE (the real use case — you enrich contacts, not yourself). These
// selectors target the common structure; they MUST be validated live against a
// third-party profile, which is the only authoritative source. Treat the
// specific selectors as a starting point; the CONTRACT (field names,
// null-on-failure, photo anchored on alt) is the stable part.
//
// Exposed as a pure function so it can be unit-tested against an HTML fixture
// (inject a `doc` to parse a fixture; defaults to the live `document`).

function extractProfile(doc = (typeof document !== "undefined" ? document : null)) {
  if (!doc) return null;

  const text = (el) => (el && el.textContent ? el.textContent.trim() : null);
  // Like `text`, but preserves visual line breaks. `textContent` flattens
  // <br>/<p>/block boundaries into a single run with NO newlines, which would
  // collapse a multi-paragraph About into one line. `innerText` reflects the
  // RENDERED text and inserts "\n" at those boundaries, so multi-paragraph
  // prose round-trips with its newlines intact. Fall back to textContent where
  // innerText is unavailable (e.g. a non-rendering test DOM).
  const blockText = (el) => {
    if (!el) return null;
    const raw = typeof el.innerText === "string" ? el.innerText : el.textContent;
    return raw ? raw.trim() : null;
  };
  const safe = (fn) => { try { return fn(); } catch { return null; } };

  // --- Name -----------------------------------------------------------------
  // Most stable: the page <title> "<Name> | LinkedIn". Cross-check against the
  // profile photo's alt ("View <Name>’s profile") so a stale tab title can't
  // silently win.
  const photoImg = doc.querySelector('img[alt^="View "][alt*="profile"]');
  const nameFromTitle = safe(() =>
    (doc.title || "").replace(/\s*[|·]\s*LinkedIn\s*$/i, "").trim() || null
  );
  const nameFromAlt = safe(() => {
    if (!photoImg) return null;
    return photoImg.getAttribute("alt")
      .replace(/^View\s+/i, "")
      .replace(/[’']s\s+profile.*$/i, "")
      .trim() || null;
  });
  const fullName = nameFromTitle || nameFromAlt;

  // --- Top card: name heading, then headline, then location -----------------
  // The name renders as an <h1>/<h2> in the top card. After it (skipping the
  // verified-badge SVG and a pronouns <p>) come the headline <p> and the
  // location <p>. We locate the heading by matching its text to the name, then
  // walk following block elements, classifying by content.
  const nameHeading = safe(() => {
    if (!fullName) return null;
    const heads = [...doc.querySelectorAll("h1, h2")];
    return heads.find((h) => text(h) === fullName) || null;
  });

  // Collect the candidate text lines in the top card after the name.
  //
  // The headline and location render as <p> elements that are NOT inside the
  // name heading's immediate wrapper — they're siblings of an ancestor a few
  // levels up. So `closest("section,div")` grabs too small a container and
  // misses them. Instead, climb the ancestor chain (bounded) and pick the first
  // ancestor that actually contains <p> text beyond the name — that's the top
  // card. Keep the climb capped so we never accidentally select <main>/<body>.
  const isPronoun = (t) =>
    /^\(?\s*(he\/him|she\/her|they\/them)/i.test(t);
  // Connection-degree badges ("· 1st", "· 2nd", "3rd+") render as their own
  // <p> elements INSIDE the name row. If they survive this filter, the
  // ancestor climb below stops at the name row and never reaches the real
  // top card — headline and location come back as degree garbage/null
  // (confirmed against a captured third-party profile, 2026-07).
  const isDegree = (t) => /^[·\s]*\d+(st|nd|rd|th)\+?$/i.test(t);
  // The "Contact info" trigger renders as a <p> in the location row.
  const isChrome = (t) => /^contact info$/i.test(t);

  const topCardLines = safe(() => {
    if (!nameHeading) return [];
    let node = nameHeading;
    for (let depth = 0; node && depth < 8; depth++, node = node.parentElement) {
      const lines = [...node.querySelectorAll("p")]
        .map((p) => text(p))
        .filter((t) => t && t !== "·" && !isPronoun(t) && !isDegree(t) && !isChrome(t));
      // The top card is the first ancestor that yields real <p> lines (the
      // headline/location). Stop as soon as we find them.
      if (lines.length) return lines;
    }
    return [];
  }) || [];

  // Headline = first non-location line that looks like a role/headline. The
  // location line characteristically reads "City, Region, Country" (comma-
  // separated place words, no "at"/"·"); the headline often contains " at ".
  const looksLikeLocation = (t) =>
    /,/.test(t) && !/\bat\b/i.test(t) && t.split(",").length >= 2 && t.length < 80;

  const headline = safe(() =>
    topCardLines.find((t) => t && !looksLikeLocation(t)) || null
  );
  const location = safe(() =>
    topCardLines.find((t) => looksLikeLocation(t)) || null
  );

  // Title / organization, best source first:
  //
  // 1. The Experience section's CURRENT position (date line contains
  //    "Present") — structured, per-role data, so it works for any headline.
  //    Lazy-rendered like About, so it may be absent on a fresh page.
  // 2. Fallback: the headline, which is free text but frequently
  //    "<Title> at <Org>[, <Title2> at <Org2>...]" — parse the FIRST "at"
  //    pair. Keep the raw headline as its own field regardless.
  const experience = safe(() => extractExperience(doc)) || [];
  const currentPosition = safe(() =>
    experience.find((p) => p.isCurrent) || null
  );

  const firstAt = safe(() => {
    if (!headline) return null;
    const seg = headline.split(/[,|·]/)[0].trim(); // first clause
    const m = seg.match(/^(.*?)\s+\bat\b\s+(.*)$/i);
    if (!m) return null;
    return { title: m[1].trim() || null, org: m[2].trim() || null };
  });
  // Take BOTH title and org from ONE source — mixing sources could pair a
  // title and an org neither asserts (a current self-employed role has
  // org: null; borrowing the org from a stale "CTO at Acme" headline would
  // fabricate "Advisor at Acme").
  const roleSource = currentPosition || firstAt;
  const title = (roleSource && roleSource.title) || null;
  const org = (roleSource && roleSource.org) || null;

  // --- About ----------------------------------------------------------------
  // Anchor on the "About" <h2> landmark, then take the bio by its DOM POSITION:
  // the content block that immediately follows the heading's block within the
  // section. We do NOT pick "the longest text block" — that heuristic is fragile
  // (a long headline/experience entry elsewhere in the section can win, and a
  // short bio can lose). The bio is positionally the first real content after
  // the "About" heading, so walk forward from there.
  //
  // Read the bio with `blockText` (innerText-based) for two reasons: it
  // preserves the bio's <br>/<p> line breaks as "\n" (textContent flattens
  // them), and it naturally excludes LinkedIn's visually-hidden screen-reader
  // duplicate of the bio (textContent would return it doubled).
  //
  // NOTE: LinkedIn lazy-renders this section, so on a fresh non-scrolled page
  // it may be absent and return null. content.js's probe mitigates that with
  // an unconditional full-page scroll pass (forceLazySections) and re-parses;
  // still best-effort.
  const about = safe(() => {
    const heads = [...doc.querySelectorAll("h1, h2, h3")];
    const aboutHead = heads.find((h) => /^about$/i.test(text(h) || ""));
    if (!aboutHead) return null;
    const section = aboutHead.closest("section") || aboutHead.parentElement;
    if (!section) return null;

    // The bio prose sits in a block AFTER the heading. Climb from the heading to
    // the ancestor that is a direct child of the section ("the heading block"),
    // then scan its following siblings for the first one carrying real prose.
    let headerBlock = aboutHead;
    while (headerBlock.parentElement && headerBlock.parentElement !== section) {
      headerBlock = headerBlock.parentElement;
    }
    let body = null;
    for (let sib = headerBlock.nextElementSibling; sib; sib = sib.nextElementSibling) {
      // Skip pure chrome (a bare "see more"/"Edit" link or button block).
      if (sib.matches("a, button")) continue;
      const t = blockText(sib);
      if (t && t.length > 0 && !/^about$/i.test(t)) { body = t; break; }
    }

    // Fallback: some layouts nest the heading and the bio under a shared wrapper
    // rather than as siblings (so there's no following sibling to find). Take the
    // section's rendered text (still attached, so innerText resolves and drops
    // the a11y duplicate) and strip the leading "About" heading line. The leading
    // /^…about…/ strip below also removes a self-view "Edit" label if present.
    if (body == null) {
      const whole = blockText(section);
      if (whole) body = whole.replace(/^\s*about\s*\n?/i, "");
    }
    if (body == null) return null;

    // Strip a glued-on heading prefix and the truncated expander suffix
    // ("…more"/"… see more"); keep the bio prose and its internal newlines.
    // NOTE: when "…more" was present the bio is TRUNCATED in the DOM until the
    // user expands it. A later pass can click the "see more" control (like the
    // Contact-info modal) to capture the full text; for now we keep the visible
    // portion.
    body = body
      .replace(/^About\s*/i, "")
      .replace(/\n*[……]\s*(see\s+)?more\s*$/i, "")
      .trim();
    return body || null;
  });

  // --- Photo URL ------------------------------------------------------------
  // We want FULL-RES. LinkedIn signs each size variant separately (the ?t= token
  // differs per size; the 800 variant can even have a different filename), so we
  // can't rewrite the size token — we must use a srcset the page actually
  // provides. The alt-anchored top-card <img> often carries ONLY the 100x100
  // `src` (no srcset). But another <img> for the SAME profile-photo asset (e.g.
  // alt="") carries the full multi-variant srcset including 800w. So: scan ALL
  // profile-displayphoto images and return the richest source — prefer a real
  // multi-variant `srcset`, else the largest single `src`. The caller picks the
  // largest entry and fetches its bytes in-session.
  const photoSrcset = safe(() => {
    const imgs = [...doc.querySelectorAll('img[src*="profile-displayphoto"], img[srcset*="profile-displayphoto"]')];
    if (!imgs.length) {
      // Last resort: the alt-anchored top-card image, whatever it has.
      return photoImg
        ? (photoImg.getAttribute("srcset") || photoImg.currentSrc || photoImg.src || null)
        : null;
    }
    // Prefer an <img> that actually has a multi-variant srcset (contains "w,"),
    // which carries the larger 400/800 sizes with valid signatures.
    const withSrcset = imgs
      .map((im) => im.getAttribute("srcset"))
      .filter((s) => s && /\d+w/.test(s));
    if (withSrcset.length) {
      // Pick the srcset whose largest descriptor is biggest.
      const maxW = (s) =>
        Math.max(...[...s.matchAll(/(\d+)w/g)].map((m) => parseInt(m[1], 10)), 0);
      return withSrcset.sort((a, b) => maxW(b) - maxW(a))[0];
    }
    // No srcset anywhere — fall back to the single src on the alt-anchored image.
    return photoImg
      ? (photoImg.getAttribute("srcset") || photoImg.currentSrc || photoImg.src || null)
      : (imgs[0].currentSrc || imgs[0].src || null);
  });

  return {
    sourceUrl: safe(() => (doc.location ? doc.location.href : null)),
    slug: safe(() => {
      const path = doc.location ? doc.location.pathname : "";
      const m = path.match(/\/in\/([^/]+)/);
      return m ? m[1] : null;
    }),
    fullName,
    headline,
    title,
    org,
    location,
    about,
    experience,
    photoSrcset,
    // Whether this profile even HAS a "Contact info" link. It lives in the top
    // card, so it's in the DOM from first paint — its presence/absence is a
    // definitive, immediate signal: a profile with no link has no contact info
    // to fetch, so the readiness gate can mark the contact section done right
    // away rather than opening an overlay that would never appear. When the
    // link IS present, content.js opens it (extractContactInfo) to capture the
    // fields. Computed on every parse so profileReadiness (which reads only the
    // parsed result) can see it throughout the scroll pass.
    hasContactInfoLink: safe(() => !!findContactInfoTrigger(doc)),
    // Debug aid for selector tuning — drop once the parser stabilizes.
    _topCardLines: topCardLines,
  };
}

// --- Experience --------------------------------------------------------------
//
// Anchor on the "Experience" <h2> landmark, then climb (bounded) to the first
// ancestor holding `componentkey^="entity-collection-item"` entry wrappers —
// that ancestor is the Experience card. Ad/suggestion cards further up the page
// ("People you may know") use similar wrappers, so the climb aborts if it ever
// reaches a node containing ANOTHER section's `ProfileNullStateCardAnchor_*`
// heading (it has climbed past the card).
//
// Entries come in two shapes (confirmed against a full-scroll capture, 2026-07):
//
//   simple   <p> lines: [title, "Org · Type", "Oct 2025 - Present · 10 mos",
//            location?, description…, skills?]
//   grouped  (several roles at ONE employer) <p> lines: [company,
//            "6 yrs 1 mo" (bare total duration), role1, dates1, …, role2,
//            dates2, …]
//
// Classification hangs on the DATE-RANGE lines (year-dash-(year|"Present"),
// short — see isDateRange):
// the line immediately BEFORE a date line is the role title (grouped) or the
// "Org · Type" line (simple); a short comma/remote line immediately AFTER is
// the location. Returns a FLAT array of positions, rendered order (most recent
// first): {title, org, employmentType, dates, isCurrent, location}. Best-effort
// like everything else: [] when the section isn't rendered (lazy-load — see the
// About note) or the shape changed.
function extractExperience(doc = (typeof document !== "undefined" ? document : null)) {
  if (!doc) return [];
  const text = (el) => (el && el.textContent ? el.textContent.trim() : null);

  // Date-range lines read "Oct 2025 - Present · 10 mos" / "Aug 2018 - Aug
  // 2021 · 3 yrs 1 mo" / "2020 - Present". Require the full
  // year-dash-(year|Present) STRUCTURE — a short prose line containing a
  // bare "present" or a stray "YYYY -" fragment must not classify as a date
  // (it would also flip isCurrent and could hijack title/org sourcing).
  const isDateRange = (t) =>
    t.length < 60 &&
    /\b(19|20)\d{2}\s*[-–]\s*(present\b|([a-z]{3,9}\.?\s+)?(19|20)\d{2}\b)/i.test(t);
  const isBareDuration = (t) =>
    /^\d+\s+(yrs?|mos?)(\s+\d+\s+mos?)?$/i.test(t);
  const looksLikePlace = (t) =>
    t.length < 60 && !/[●•]/.test(t) && !/\bskills?$/i.test(t) &&
    (/,/.test(t) || /\b(remote|hybrid|on-site)\b/i.test(t));

  const heads = [...doc.querySelectorAll("h1, h2, h3")];
  const expHead = heads.find((h) => /^experience$/i.test(text(h) || ""));
  if (!expHead) return [];

  // Climb to the Experience card: the first ancestor with entry wrappers.
  let entries = [];
  for (let node = expHead, depth = 0; node && depth < 10; depth++, node = node.parentElement) {
    // Climbed past the card into a container holding ANOTHER section's
    // null-state anchor (Education, Interests, …)? Abort rather than swallow
    // that section's (or an ad card's) entries — this check must run BEFORE
    // the item check so a spanning container never wins. Match anchors by
    // componentkey VALUE: the Experience anchor is usually the very heading
    // we text-matched, but nothing guarantees the attribute sits on it, and
    // identity comparison would false-abort on the card's own anchor (or a
    // breakpoint duplicate) in that case.
    const anchors = [...node.querySelectorAll('[componentkey^="ProfileNullStateCardAnchor_"]')];
    if (anchors.some((a) => (a.getAttribute("componentkey") || "") !== "ProfileNullStateCardAnchor_Experience")) break;
    const items = node.querySelectorAll('[componentkey^="entity-collection-item"]');
    if (items.length) { entries = [...items]; break; }
  }

  const positions = [];
  for (const entry of entries) {
    const lines = [...entry.querySelectorAll("p")].map(text).filter(Boolean);
    const dateIdxs = lines
      .map((t, i) => (isDateRange(t) ? i : -1))
      .filter((i) => i > 0); // a date line needs a title/org line before it
    if (!dateIdxs.length) continue; // undated entry — can't classify, skip

    const grouped = lines.length > 1 && isBareDuration(lines[1]);
    for (const di of dateIdxs) {
      const before = lines[di - 1];
      const after = lines[di + 1];
      const dates = lines[di];
      const location = after && looksLikePlace(after) ? after : null;
      // "- Present" specifically (the open end of the range), not any word
      // "present" that happens to appear in the line.
      const isCurrent = /[-–]\s*present\b/i.test(dates);
      if (grouped) {
        // [company, total-duration, role, dates, …]: line before each date
        // line is that role's title; the employer is the entry's first line.
        if (before === lines[0] || isBareDuration(before)) continue;
        positions.push({
          title: before, org: lines[0], employmentType: null,
          dates, isCurrent, location,
        });
      } else {
        // [title, "Org · Type", dates, …]: only the FIRST date line belongs
        // to the entry itself (later ones are inside the description). When
        // the date line directly follows the title (di == 1) there is no org
        // line at all (e.g. self-employed) — don't mistake the title for it.
        if (di !== dateIdxs[0]) continue;
        const orgParts = di >= 2
          ? before.split("·").map((s) => s.trim()).filter(Boolean)
          : [];
        positions.push({
          title: lines[0], org: orgParts[0] || null,
          employmentType: orgParts[1] || null,
          dates, isCurrent, location,
        });
      }
    }
  }
  return positions;
}

// --- Contact info (click-then-parse) ----------------------------------------
//
// Emails, websites, and the canonical profile URL are NOT in the page DOM — they
// live behind the "Contact info" link, which opens an overlay/dialog. This is an
// async, STATEFUL interaction: open the overlay, wait for it, parse it, then
// restore the page (close it). Only do this on explicit user action.
//
// The trigger is a stable anchor: an <a href> ending in "/overlay/contact-info/"
// (more stable than the visible "Contact info" text, which can be localized).
// Clicking it lets LinkedIn's SPA open the modal in place.

// Also used by content.js (forceLazySections) — the two files share the
// content-script world. Don't rename or remove without updating it.
function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Poll for a value until truthy or the attempts run out. Never hangs.
async function waitFor(fn, { tries = 25, intervalMs = 120 } = {}) {
  for (let i = 0; i < tries; i++) {
    let v = null;
    try { v = fn(); } catch { v = null; }
    if (v) return v;
    await sleep(intervalMs);
  }
  return null;
}

function findContactInfoTrigger(doc) {
  // Prefer the stable href; fall back to the accessible text/aria-label.
  const byHref = doc.querySelector('a[href*="/overlay/contact-info/"]');
  if (byHref) return byHref;
  return [...doc.querySelectorAll("a, button")].find((el) => {
    const t = (el.textContent || el.getAttribute("aria-label") || "").trim();
    return /contact info/i.test(t);
  }) || null;
}

// LinkedIn wraps external website links in a safety redirect:
//   https://www.linkedin.com/safety/go/?url=<encoded real url>&urlhash=...
// Unwrap to the real destination so we store "https://adamwulf.me", not the
// redirect. Returns the input unchanged if it isn't a safety link.
function unwrapSafetyURL(href) {
  try {
    if (!/linkedin\.com\/safety\/go\//i.test(href)) return href;
    const u = new URL(href);
    const real = u.searchParams.get("url");
    return real ? decodeURIComponent(real) : href;
  } catch {
    return href;
  }
}

async function extractContactInfo(doc = (typeof document !== "undefined" ? document : null)) {
  if (!doc) return null;
  const safe = (fn) => { try { return fn(); } catch { return null; } };

  const trigger = findContactInfoTrigger(doc);
  if (!trigger) return null;

  // Open the overlay. preventDefault keeps the SPA in place rather than a full
  // navigation; if the SPA ignores that, the modal still opens.
  trigger.click();

  // Locate the contact-details dialog element (frame). Most specific first: the
  // SDUI contact-details overlay screen and the dialog-content testid (confirmed
  // in a captured open panel). Fall back to a role="dialog" whose text actually
  // mentions contact fields, so we never grab an ambient aria-live dialog
  // (toasts use role="dialog" too).
  const findDialog = () => {
    const sdui = doc.querySelector('[data-sdui-screen*="ProfileContactDetails" i]');
    if (sdui) return sdui.closest('[role="dialog"]') || sdui;
    const byTestId = doc.querySelector('[data-testid="dialog-content"]');
    if (byTestId && /email|website|contact/i.test(byTestId.textContent || "")) {
      return byTestId.closest('[role="dialog"]') || byTestId;
    }
    const d = [...doc.querySelectorAll('[role="dialog"]')]
      .find((x) => /\b(email|website|contact info)\b/i.test(x.textContent || ""));
    return d || null;
  };

  // A dialog whose CONTACT FIELDS have loaded — the frame can mount a beat
  // before its links populate, so waiting only for the frame can parse an empty
  // panel. Consider it loaded once it carries an actual field link: a mailto,
  // an external website, or the canonical /in/<slug> profile URL (the last is
  // always present in a contact-details panel, so it's the reliable floor even
  // for a profile that lists neither email nor site).
  const dialogLoaded = () => {
    const d = findDialog();
    if (!d) return null;
    const hasField = [...d.querySelectorAll('a[href]')].some((a) => {
      const href = a.getAttribute("href") || "";
      // Match the scheme tests CASE-SENSITIVELY to mirror the extraction's CSS
      // selectors (a[href^="mailto:"], a[href^="http"]) — an attribute `^=`
      // match is case-sensitive, so a case-insensitive predicate here could
      // report "loaded" on a link (e.g. "MAILTO:") the parse would then skip.
      if (/^mailto:/.test(href)) return true;
      if (/^http/.test(href) && !/(^https?:\/\/)?([^/]*\.)?linkedin\.com/i.test(unwrapSafetyURL(a.href))) return true;
      if (/\/in\/[^/]+\/?($|\?)/.test(a.href) && !/\/overlay\//.test(a.href)) return true;
      return false;
    });
    return hasField ? d : null;
  };

  // Wait for the fields to load, not just the frame. If the frame opens but no
  // field ever lands (a genuinely empty panel, or a shape we don't recognize),
  // fall back to whatever frame we found so we still close it and return the
  // (empty) shape rather than hang — waitFor is bounded and never hangs.
  const dialog = (await waitFor(dialogLoaded)) || findDialog();
  if (!dialog) return null;

  const uniq = (arr) => [...new Set(arr.filter(Boolean))];

  const info = {
    profileUrl: safe(() => {
      // The CANONICAL public profile URL — "linkedin.com/in/<slug>" with nothing
      // trailing. The dialog also contains many /in/<slug>/edit/…, /details/…,
      // /overlay/… links; exclude those and prefer the bare canonical form.
      const links = [...dialog.querySelectorAll('a[href*="/in/"]')]
        .map((x) => x.href)
        .filter((h) => /\/in\/[^/]+\/?($|\?)/.test(h) && !/\/overlay\//.test(h));
      // Prefer the shortest (the clean canonical one), strip a trailing slash.
      const best = links.sort((a, b) => a.length - b.length)[0];
      return best ? best.replace(/\/$/, "") : null;
    }),
    emails: safe(() =>
      uniq([...dialog.querySelectorAll('a[href^="mailto:"]')]
        .map((a) => a.getAttribute("href").replace(/^mailto:/, "").trim()))
    ) || [],
    websites: safe(() =>
      uniq([...dialog.querySelectorAll('a[href^="http"]')]
        .map((a) => unwrapSafetyURL(a.href))
        // After unwrapping, drop anything still on linkedin.com (the profile
        // link, the safety host itself, internal nav).
        .filter((h) => h && !/(^https?:\/\/)?([^/]*\.)?linkedin\.com/i.test(h)))
    ) || [],
  };

  // Restore page state: close the dialog (Esc, or a close/dismiss button).
  safe(() => {
    const closeBtn = dialog.querySelector(
      '[aria-label*="Dismiss" i], [aria-label*="Close" i], button[aria-label]'
    );
    if (closeBtn) closeBtn.click();
    else doc.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });

  return info;
}

// --- Readiness ---------------------------------------------------------------
//
// "Have we parsed everything we need yet?" — the single source of truth for the
// scroll-until-loaded gate in content.js and the "X/Y sections loaded" progress
// UI in the popup. LinkedIn lazy-renders sections as they scroll into view, so a
// fresh page has only the top card; the scroll pass mounts the rest. Rather than
// scroll on a blind "stopped growing" heuristic and hope the sections we care
// about came along, we drive the scroll until THESE required sections are all
// present, then hand off.
//
// ALL four sections are `required: true` — this readiness object is how the
// popup shows "X/4 loaded" and gates the handoff. But the RUNTIME wait in
// content.js is deliberately asymmetric, because the sections mount by
// different means:
//
//   • identity, Experience, About — mount by SCROLLING. content.js's scroll
//     pass is unbounded (no deadline): it loops top→bottom until all three are
//     present. So if one of THESE is missing (a slow load, or a profile with no
//     About text), the pass keeps scrolling and the only way to hand off is the
//     user's "Save anyway" (which interrupts and ships what parsed).
//   • Contact info — the "Contact info" link lives in the top card (in the DOM
//     from first paint), so its presence/absence is a definitive, immediate
//     signal via `hasContactInfoLink`. No link => nothing to fetch => the
//     section is done at once (a contactless profile reaches 4/4 on its own,
//     no overlay needed). Link present => content.js opens the overlay ONCE
//     after the scroll sections are up, waits for the fields to load, and
//     stamps `result.contactInfo`; the section is done when those fields land.
//
// Net: identity/Experience/About block until present-or-"Save anyway"; contact
// info blocks only when a link exists but its fields haven't loaded yet.
//
// Each check reads ONLY the already-parsed `result` (no DOM access), so the same
// function serves the live probe and the unit tests against a fixture.
function profileReadiness(result) {
  const r = result || {};
  // The contact section is DONE in either of two ways:
  //   1. This profile has NO "Contact info" link (hasContactInfoLink === false)
  //      — the link lives in the top card and is in the DOM from first paint,
  //      so its absence definitively means there's nothing to fetch. Mark it
  //      done immediately rather than waiting on an overlay that never appears.
  //   2. We opened the overlay and captured at least one real field (a canonical
  //      profile URL, an email, or a website). An opened-but-empty overlay (`{}`)
  //      does NOT count on its own — but such a profile would also have had a
  //      link, so case 1 doesn't rescue it; it stays pending until fields load.
  // A profile whose link is present but not yet opened is pending (neither case).
  const ci = r.contactInfo;
  const capturedContact = !!(
    ci &&
    (ci.profileUrl ||
      (Array.isArray(ci.emails) && ci.emails.length > 0) ||
      (Array.isArray(ci.websites) && ci.websites.length > 0))
  );
  const noContactLink = r.hasContactInfoLink === false;
  const hasContact = capturedContact || noContactLink;
  const sections = [
    // The top-card identity is present as soon as the page paints — it gates
    // nothing in practice, but reporting it gives the popup a "1/N" the instant
    // the probe starts rather than a cold 0.
    { key: "identity", label: "Profile", required: true, present: !!r.fullName },
    // Experience mounts lazily near the middle of the page, so it's one of the
    // sections the scroll pass has to reach.
    { key: "experience", label: "Experience", required: true,
      present: Array.isArray(r.experience) && r.experience.length > 0 },
    // About also lazy-mounts. Some profiles have no About text; with no
    // deadline, such a profile waits for the user's "Save anyway" rather than
    // shipping on a timer.
    { key: "about", label: "About", required: true, present: !!r.about },
    // Contact info: done if the profile has no "Contact info" link at all (no
    // fetch needed) or the overlay step captured fields. See hasContact above.
    { key: "contact", label: "Contact info", required: true, present: hasContact },
  ];
  const required = sections.filter((s) => s.required);
  return {
    sections,
    // Ready = every REQUIRED section is present.
    ready: required.every((s) => s.present),
    // The "X/Y" progress counts the required sections we're waiting for.
    loaded: required.filter((s) => s.present).length,
    total: required.length,
  };
}

// Export for the unit-test harness (Node) without breaking the browser, where
// `module` is undefined and the function is just a global in the page context.
if (typeof module !== "undefined" && module.exports) {
  module.exports = { extractProfile, extractExperience, extractContactInfo, profileReadiness };
}
