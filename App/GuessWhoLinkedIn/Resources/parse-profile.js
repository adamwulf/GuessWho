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

  const topCardLines = safe(() => {
    if (!nameHeading) return [];
    let node = nameHeading;
    for (let depth = 0; node && depth < 8; depth++, node = node.parentElement) {
      const lines = [...node.querySelectorAll("p")]
        .map((p) => text(p))
        .filter((t) => t && t !== "·" && !isPronoun(t));
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

  // Title / organization: LinkedIn's headline is free text, frequently
  // "<Title> at <Org>[, <Title2> at <Org2>...]". Parse the FIRST "at" pair as
  // the primary current role; keep the raw headline regardless.
  const firstAt = safe(() => {
    if (!headline) return null;
    const seg = headline.split(/[,|·]/)[0].trim(); // first clause
    const m = seg.match(/^(.*?)\s+\bat\b\s+(.*)$/i);
    if (!m) return null;
    return { title: m[1].trim() || null, org: m[2].trim() || null };
  });
  const title = firstAt ? firstAt.title : null;
  const org = firstAt ? firstAt.org : null;

  // --- About ----------------------------------------------------------------
  // Anchor on the "About" <h2> landmark, then take the longest text block in
  // its following section (skips Edit links / icons present in self-view).
  const about = safe(() => {
    const heads = [...doc.querySelectorAll("h1, h2, h3")];
    const aboutHead = heads.find((h) => /^about$/i.test(text(h) || ""));
    if (!aboutHead) return null;
    const section = aboutHead.closest("section") || aboutHead.parentElement;
    if (!section) return null;
    // Candidate text nodes within the section, excluding the heading itself and
    // obvious chrome (links/buttons). Pick the longest — the bio is the body.
    const candidates = [...section.querySelectorAll("span, p, div")]
      .filter((el) => !el.closest("a, button"))
      .map((el) => text(el))
      .filter((t) => t && t.length > 0 && !/^about$/i.test(t));
    if (!candidates.length) return null;
    let body = candidates.reduce((a, b) => (b.length > a.length ? b : a), "");
    // The longest block can include the section heading text glued to the front
    // ("About<bio>") and the truncated expander suffix ("…more"/"… see more").
    // Strip both so we keep just the bio prose.
    // NOTE: when "…more" was present the bio is TRUNCATED in the DOM until the
    // user expands it. A later pass can click the "see more" control (like the
    // Contact-info modal) to capture the full text; for now we keep the visible
    // portion.
    body = body
      .replace(/^About\s*/i, "")
      .replace(/[……]\s*(see\s+)?more\s*$/i, "")
      .trim();
    return body || null;
  });

  // --- Photo URL ------------------------------------------------------------
  // The photo <img>'s src is a media.licdn.com CDN URL; srcset carries multiple
  // sizes. We return the srcset/src so the caller can pick a small variant and
  // fetch the BYTES in-session (the URL itself may reject out-of-browser
  // fetches like the profile page does).
  const photoSrcset = safe(() => {
    if (!photoImg) return null;
    return photoImg.getAttribute("srcset") || photoImg.currentSrc || photoImg.src || null;
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
    photoSrcset,
    // Debug aid for selector tuning — the raw top-card lines the climb found.
    // Lets us see WHY headline/location classified the way they did. Drop this
    // once the parser stabilizes.
    _topCardLines: topCardLines,
  };
}

// Export for the unit-test harness (Node) without breaking the browser, where
// `module` is undefined and the function is just a global in the page context.
if (typeof module !== "undefined" && module.exports) {
  module.exports = { extractProfile };
}
