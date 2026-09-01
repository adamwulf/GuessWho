import fs from "node:fs";
import { createRequire } from "node:module";

const { parseHTML } = await import("linkedom");
const require = createRequire(import.meta.url);
const parserModule = require("../Resources/parse-profile.js");
const {
  compactTLSPhotoForHandoff,
  extractContactInfo,
  extractProfile,
  extractRiceBusinessProfile,
  extractRiceProfile,
  extractTLSProfiles,
  fitTLSBatchToHandoffCap,
  profileReadiness,
  tlsHandoffEnvelopeByteSize,
} = parserModule;

const tlsURL = "https://tls26-s2-people.netlify.app/";
const handoffCapBytes = 8 * 1024 * 1024;
let assertions = 0;

function documentFor(html, url = tlsURL) {
  const { document } = parseHTML(html);
  Object.defineProperty(document, "location", {
    configurable: true,
    value: new URL(url),
  });
  if (!document.images) {
    Object.defineProperty(document, "images", {
      configurable: true,
      get() { return document.querySelectorAll("img"); },
    });
  }
  return document;
}

function equal(actual, expected, label) {
  assertions += 1;
  if (actual !== expected) {
    throw new Error(`${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

const fixture = documentFor(`
  <div class="pcard">
    <div class="avatar"><img src="/a.jpg" srcset="/a-small.jpg 100w, /a-large.jpg 800w"></div>
    <div class="pname">Anthony<span class="goesby">“Tony”</span> Santa Ana<span class="pron">he/him</span></div>
    <div class="prole">K-12 Teacher</div>
    <div class="pmeta">
      <div class="mrow"><span>✎</span><span>Ethnic Studies</span></div>
      <div class="mrow"><span>🏛</span><span>San Jose City College</span></div>
      <div class="mrow"><span>📍</span><span>San Jose, CA</span></div>
    </div>
    <div class="ama"><ul><li>Teaching on a boat</li><li>Cutii art show</li></ul></div>
  </div>
  <div class="pcard">
    <div class="avatar"><img src="data:image/png;base64,AQIDBA=="></div>
    <div class="prole">Director of Photography</div>
  </div>
`);
const fixtureBatch = extractTLSProfiles(fixture);
equal(fixtureBatch.profiles.length, 2, "fixture card count");
equal(fixtureBatch.profiles[0].fullName, "Anthony Santa Ana", "nested-label name");
equal(fixtureBatch.profiles[0].nickname, "Tony", "nickname");
equal(fixtureBatch.profiles[0].role, "K-12 Teacher", "role category");
equal("title" in fixtureBatch.profiles[0], false, "role not copied to title");
equal(fixtureBatch.profiles[0].department, "Ethnic Studies", "department icon");
equal(fixtureBatch.profiles[0].org, "San Jose City College", "org icon");
equal(fixtureBatch.profiles[0].location, "San Jose, CA", "location icon");
equal(fixtureBatch.profiles[0].ama.length, 2, "AMA values");
equal(fixtureBatch.profiles[1].title, "Director of Photography", "title-like role");
equal(fixtureBatch.profiles[1].photo.byteLength, 4, "inline photo byte count");

// Foundation's JSONSerialization(.prettyPrinted), used by the Safari handoff,
// escapes slashes and spaces property colons. This exact byte count was
// independently produced by JSONSerialization for the same envelope.
const foundationSizingFixture = {
  source: "tls",
  sourceUrl: tlsURL,
  profiles: [{
    fullName: "Slash / Colon:",
    photo: {
      dataURL: "data:image/png;base64,A/B",
      contentType: "image/png",
      byteLength: 2,
    },
  }],
};
equal(
  tlsHandoffEnvelopeByteSize(foundationSizingFixture),
  366,
  "Foundation pretty-printed envelope byte compatibility"
);
const foundationEscapedValueFixture = {
  source: "tls",
  profiles: [{
    fullName: "line\u2028sep",
    role: "para\u2029sep",
    org: 'quote":colon',
    department: "emoji😀",
    location: "tab\tline\n",
  }],
};
equal(
  tlsHandoffEnvelopeByteSize(foundationEscapedValueFixture),
  285,
  "Foundation sizing ignores colon-like text inside escaped values"
);

const linkedIn = extractProfile(documentFor(`
  <main><section><h1>Ada Lovelace</h1><p>Engineer at Analytical Engines</p><p>London, England</p></section></main>
`, "https://www.linkedin.com/in/ada-lovelace/"));
equal(linkedIn.fullName, "Ada Lovelace", "LinkedIn name regression");
equal(linkedIn.title, "Engineer", "LinkedIn title regression");

const rice = extractRiceProfile(documentFor(`
  <article class="article--bio">
    <h1 class="article__author-name profile">Grace Hopper</h1>
    <div class="article__author-role profile">Professor</div>
    <div class="article__author-contact">
      <div class="article__author-role profile top-border">Computer Science</div>
    </div>
  </article>
`, "https://profiles.rice.edu/faculty/grace-hopper"));
equal(rice.fullName, "Grace Hopper", "Rice name regression");
equal(rice.department, "Computer Science", "Rice department regression");

const riceBusinessFixtureURL = new URL(
  "./fixtures/rice-business-person-sanitized.html", import.meta.url
);
const riceBusiness = extractRiceBusinessProfile(documentFor(
  fs.readFileSync(riceBusinessFixtureURL, "utf8"),
  "https://business.rice.edu/person/elena-naids"
));
equal(riceBusiness.source, "rice", "Rice Business source");
equal(riceBusiness.slug, "elena-naids", "Rice Business slug");
equal(riceBusiness.fullName, "Elena Naids", "Rice Business name");
equal(riceBusiness.title, "Lecturer in Entrepreneurship", "Rice Business title");
equal(riceBusiness.department, "Faculty", "Rice Business department");
equal(riceBusiness.about, "Design researcher and strategist.", "Rice Business biography");
equal(riceBusiness.contactInfo.emails.join(","), "elena.naids@rice.edu", "Rice Business email");
equal(riceBusiness.contactInfo.phones.join(","), "+1-713-348-4622", "Rice Business phone");
equal(
  riceBusiness.contactInfo.websites.join(","),
  "https://portfolio.example/elena",
  "Rice Business keeps only HTTP(S) contact websites"
);
equal(
  riceBusiness.photoSrcset,
  "https://business.rice.edu/sites/default/files/styles/1_1_720x720/public/elena-naids.jpg",
  "Rice Business visible profile photo wins over metadata"
);
const riceBusinessMetadataOnly = extractRiceBusinessProfile(documentFor(`
  <meta property="og:title" content="Social Title | Rice Business">
  <meta property="og:description" content="A social description, not a job title">
  <main id="main-content"><div class="t--profile"></div></main>
`, "https://business.rice.edu/person/metadata-only"));
equal(riceBusinessMetadataOnly.fullName, null, "Rice Business rejects og:title as a name");
equal(riceBusinessMetadataOnly.title, null, "Rice Business rejects og:description as a title");
const safariManifest = JSON.parse(fs.readFileSync(
  new URL("../Resources/manifest.json", import.meta.url), "utf8"
));
equal(
  safariManifest.host_permissions.includes("https://business.rice.edu/*"),
  true,
  "Safari manifest grants Rice Business access"
);
equal(
  safariManifest.content_scripts.some((script) =>
    script.matches.includes("https://business.rice.edu/person/*")),
  true,
  "Safari manifest injects on Rice Business people"
);
const chromeManifest = JSON.parse(fs.readFileSync(
  new URL("../../GuessWhoChrome/Sources/manifest.template.json", import.meta.url), "utf8"
));
equal(
  chromeManifest.content_scripts.some((script) =>
    script.matches.includes("https://business.rice.edu/person/*")),
  true,
  "Chrome manifest injects on Rice Business people"
);
const popupSource = fs.readFileSync(new URL("../Resources/popup.js", import.meta.url), "utf8");
equal(
  popupSource.includes("business\\.rice\\.edu\\/person"),
  true,
  "popup accepts Rice Business person URLs"
);

// The checked-in fixture is a privacy-safe structural derivative of the saved
// rendered TLS page. Keep it mandatory so a clean checkout always exercises
// the production phead/pleft/meta/AMA layout and a full 45-card batch.
const sanitizedFixtureURL = new URL("./fixtures/tls-people-sanitized.html", import.meta.url);
const sanitizedBatch = extractTLSProfiles(
  documentFor(fs.readFileSync(sanitizedFixtureURL, "utf8"))
);
equal(sanitizedBatch.profiles.length, 45, "sanitized fixture record count");
equal(sanitizedBatch.profiles[0].fullName, "Person 00", "sanitized first record");
equal(sanitizedBatch.profiles[4].fullName, "Person 04", "sanitized nested-label name");
equal(sanitizedBatch.profiles[4].nickname, "Four", "sanitized nickname");
equal(sanitizedBatch.profiles[7].role, "K-12 Teacher", "sanitized role category");
equal("title" in sanitizedBatch.profiles[7], false, "sanitized role stays role");
equal(sanitizedBatch.profiles[9].role, "Faculty", "sanitized Faculty role");
equal("title" in sanitizedBatch.profiles[9], false, "sanitized Faculty stays role-only");
equal(sanitizedBatch.profiles[13].role, "Higher Ed", "sanitized Higher Ed role");
equal("title" in sanitizedBatch.profiles[13], false, "sanitized Higher Ed stays role-only");
equal(
  sanitizedBatch.profiles[8].title,
  "Program Manager & Wellness Captain",
  "sanitized title"
);
equal(sanitizedBatch.profiles[44].fullName, "Person 44", "sanitized last record");
equal(
  sanitizedBatch.profiles.filter((profile) => profile.photo).length,
  44,
  "sanitized photo count"
);
for (const profile of sanitizedBatch.profiles) compactTLSPhotoForHandoff(profile);
const sanitizedBudget = fitTLSBatchToHandoffCap(sanitizedBatch);
equal(sanitizedBudget.droppedPhotoIndexes.length, 0, "sanitized fixture keeps every photo");
equal(sanitizedBudget.byteSize, 18292, "sanitized Foundation envelope byte size");

// A standard, dependency-local 45-person DOM always checks record count,
// order, optional photos, title/role mapping, and envelope sizing.
const generatedCards = Array.from({ length: 45 }, (_, index) => {
  const name = index === 0 ? "Adam Wulf" : (index === 44 ? "Ying Ma" : `Person ${index}`);
  const nameHTML = index === 4
    ? 'Anthony<span class="goesby">“Tony”</span> Santa Ana<span class="pron">he/him</span>'
    : name;
  const role = index === 7
    ? "K-12 Teacher"
    : (index === 8 ? "Program Manager & Wellness Captain" : "Faculty, Higher Ed");
  const avatar = index === 5
    ? '<div class="avatar">A</div>'
    : '<div class="avatar"><img src="data:image/png;base64,AQIDBA=="></div>';
  return `
    <div class="pcard">
      ${avatar}
      <div class="pname">${nameHTML}</div>
      <div class="prole">${role}</div>
      <div class="pmeta">
        <div class="mrow"><span>✎</span><span>Department ${index}</span></div>
        <div class="mrow"><span>🏛</span><span>Organization ${index}</span></div>
        <div class="mrow"><span>📍</span><span>Location ${index}</span></div>
      </div>
      <div class="ama"><ul><li>Topic ${index}</li></ul></div>
    </div>`;
}).join("");
const generatedBatch = extractTLSProfiles(documentFor(generatedCards));
equal(generatedBatch.profiles.length, 45, "generated record count");
equal(generatedBatch.profiles[0].fullName, "Adam Wulf", "generated first record");
equal(generatedBatch.profiles[4].fullName, "Anthony Santa Ana", "generated nested-label name");
equal(generatedBatch.profiles[4].nickname, "Tony", "generated nickname");
equal(generatedBatch.profiles[7].role, "K-12 Teacher", "generated role category");
equal("title" in generatedBatch.profiles[7], false, "generated role stays role");
equal(generatedBatch.profiles[8].title, "Program Manager & Wellness Captain", "generated title");
equal(generatedBatch.profiles[44].fullName, "Ying Ma", "generated last record");
equal(generatedBatch.profiles.filter((profile) => profile.photo).length, 44, "generated photo count");
for (const profile of generatedBatch.profiles) compactTLSPhotoForHandoff(profile);
const generatedBudget = fitTLSBatchToHandoffCap(generatedBatch);
equal(generatedBudget.droppedPhotoIndexes.length, 0, "generated payload keeps every photo");
equal(
  generatedBudget.byteSize,
  tlsHandoffEnvelopeByteSize(generatedBatch),
  "generated envelope byte measurement"
);
equal(generatedBudget.byteSize < handoffCapBytes, true, "generated payload fits handoff cap");

const oversized = {
  source: "tls",
  sourceUrl: tlsURL,
  profiles: [3000, 2000, 500].map((length, index) => ({
    fullName: `Oversized ${index}`,
    photo: {
      dataURL: "data:image/png;base64," + "A".repeat(length),
      contentType: "image/png",
      byteLength: length,
    },
  })),
};
const oversizedBudget = fitTLSBatchToHandoffCap(oversized, 4000);
equal(JSON.stringify(oversizedBudget.droppedPhotoIndexes), "[0]", "largest photo drops first");
equal(oversized.profiles[0].photoError, "payload-cap", "cap omission is reported per profile");
equal(oversized.profiles.length, 3, "cap fitting preserves profile order/count");

// Load content.js with extension/browser and photo-fetch stubs, then drive its
// real message listener. This covers TLS routing, mixed photo outcomes,
// fallback batch shape, runtime cap enforcement, and Rice/LinkedIn routing.
let contentListener = null;
globalThis.browser = {
  runtime: {
    onMessage: { addListener(listener) { contentListener = listener; } },
    sendMessage() { return Promise.resolve({}); },
  },
};
Object.assign(globalThis, parserModule);
globalThis.FileReader = class {
  readAsDataURL(blob) {
    blob.arrayBuffer().then((buffer) => {
      this.result = `data:${blob.type || "application/octet-stream"};base64,${Buffer.from(buffer).toString("base64")}`;
      this.onload();
    }, (error) => {
      this.error = error;
      this.onerror();
    });
  }
};
globalThis.fetch = async (url) => {
  if (String(url).startsWith("data:image/png;base64,")) {
    return new Response(new Uint8Array([1, 2, 3, 4]), {
      status: 200,
      headers: { "content-type": "image/png" },
    });
  }
  if (String(url).includes("good.jpg")) {
    return new Response(new Uint8Array([1, 2, 3]), {
      status: 200,
      headers: { "content-type": "image/jpeg" },
    });
  }
  return new Response("", { status: 404 });
};
const contentDocument = documentFor(`
  <div class="pcard"><div class="avatar"><img src="data:image/png;base64,AQIDBA=="></div><div class="pname">Inline</div></div>
  <div class="pcard"><div class="avatar"><img src="https://photos.example/good.jpg"></div><div class="pname">Fetched</div></div>
  <div class="pcard"><div class="avatar"><img src="https://photos.example/missing.jpg"></div><div class="pname">Missing</div></div>
`);
globalThis.document = contentDocument;
globalThis.location = contentDocument.location;
globalThis.window = contentDocument.defaultView || {};
globalThis.window.scrollTo = () => {};
globalThis.getComputedStyle = () => ({ overflowY: "visible" });
require("../Resources/content.js");
equal(typeof contentListener, "function", "content listener registered");

async function sendProbe(probeId) {
  return await new Promise((resolve, reject) => {
    const keepOpen = contentListener(
      { type: "guesswho.probe", probeId },
      {},
      resolve
    );
    if (keepOpen !== true) reject(new Error("probe message channel did not stay open"));
  });
}

const mixedPhotos = await sendProbe("mixed-photos");
equal(mixedPhotos.source, "tls", "content routes TLS source");
equal(
  mixedPhotos.profiles.map((profile) => profile.fullName).join(","),
  "Inline,Fetched,Missing",
  "parallel photo work preserves page order"
);
equal(mixedPhotos.profiles[0].photo.byteLength, 4, "content keeps inline photo");
equal(mixedPhotos.profiles[1].photo.byteLength, 3, "content attaches fetched photo");
equal(mixedPhotos.profiles[2].photoError, "http-404", "one failed photo is isolated");

globalThis.extractTLSProfiles = () => { throw new Error("fixture parser failure"); };
const fallback = await sendProbe("tls-fallback");
equal(fallback.source, "tls", "TLS fallback source");
equal(Array.isArray(fallback.profiles), true, "TLS fallback remains batch-shaped");
equal(fallback.profiles.length, 0, "TLS fallback cannot create a blank person");
equal(!!fallback.importError, true, "TLS fallback explains the failure to the app");

globalThis.extractTLSProfiles = () => ({
  source: "tls",
  sourceUrl: tlsURL,
  profiles: [0, 1].map((index) => ({
    fullName: `Capped ${index}`,
    photo: {
      dataURL: "data:image/png;base64," + "A".repeat(1200),
      contentType: "image/png",
      byteLength: 900,
    },
    photoSrcset: "data:image/png;base64," + "A".repeat(1200),
  })),
});
globalThis.fitTLSBatchToHandoffCap = (batch) => fitTLSBatchToHandoffCap(batch, 1800);
const capped = await sendProbe("tls-cap");
equal(capped.profiles.length, 2, "content cap preserves people");
equal(capped.profiles[0].photoError, "payload-cap", "content enforces cap");
equal(!!capped.profiles[1].photo, true, "content keeps photos that fit");

globalThis.fitTLSBatchToHandoffCap = fitTLSBatchToHandoffCap;
globalThis.extractTLSProfiles = extractTLSProfiles;
const riceContentDocument = documentFor(`
  <article class="article--bio">
    <h1 class="article__author-name profile">Grace Hopper</h1>
    <div class="article__author-role profile">Professor</div>
    <div class="article__image"><img src="data:image/png;base64,AQIDBA=="></div>
  </article>
`, "https://profiles.rice.edu/faculty/grace-hopper");
globalThis.document = riceContentDocument;
globalThis.location = riceContentDocument.location;
const riceProbe = await sendProbe("rice-route");
equal(riceProbe.source, "rice", "content routes Rice source");
equal(riceProbe.fullName, "Grace Hopper", "Rice content result remains single-profile");
equal("profiles" in riceProbe, false, "Rice content result is not a batch");

const riceBusinessContentDocument = documentFor(`
  <main id="main-content"><div class="t--profile">
    <div class="title-hero"><h1>Elena Naids</h1><p>Lecturer in Entrepreneurship</p></div>
  </div></main>
`, "https://business.rice.edu/person/elena-naids");
globalThis.document = riceBusinessContentDocument;
globalThis.location = riceBusinessContentDocument.location;
const riceBusinessProbe = await sendProbe("rice-business-route");
equal(riceBusinessProbe.source, "rice", "content routes Rice Business source");
equal(riceBusinessProbe.slug, "elena-naids", "content routes Rice Business person slug");
equal(riceBusinessProbe.fullName, "Elena Naids", "Rice Business content result");

globalThis.extractProfile = () => ({
  source: "linkedin",
  sourceUrl: "https://www.linkedin.com/in/ada-lovelace/",
  fullName: "Ada Lovelace",
  about: "Computing pioneer",
  experience: [{ title: "Engineer", isCurrent: true }],
  hasContactInfoLink: false,
  photoSrcset: "data:image/png;base64,AQIDBA==",
});
globalThis.profileReadiness = profileReadiness;
globalThis.extractContactInfo = extractContactInfo;
const linkedInContentDocument = documentFor(
  "<main><h1>Ada Lovelace</h1></main>",
  "https://www.linkedin.com/in/ada-lovelace/"
);
globalThis.document = linkedInContentDocument;
globalThis.location = linkedInContentDocument.location;
globalThis.window = linkedInContentDocument.defaultView || {};
globalThis.window.scrollTo = () => {};
const linkedInProbe = await sendProbe("linkedin-route");
equal(linkedInProbe.source, "linkedin", "content routes LinkedIn source");
equal(linkedInProbe.fullName, "Ada Lovelace", "LinkedIn content result remains single-profile");
equal(linkedInProbe.readiness.ready, true, "LinkedIn readiness path remains active");

const result = {
  passed: true,
  assertions,
  generatedRecords: generatedBatch.profiles.length,
  generatedPhotos: generatedBatch.profiles.filter((profile) => profile.photo).length,
  generatedPayloadBytes: generatedBudget.byteSize,
  sanitizedRecords: sanitizedBatch.profiles.length,
  sanitizedPhotos: sanitizedBatch.profiles.filter((profile) => profile.photo).length,
  sanitizedPayloadBytes: sanitizedBudget.byteSize,
  handoffCapBytes,
};
const savedPage = process.argv[2];
if (savedPage && !fs.existsSync(savedPage)) {
  throw new Error(`saved TLS page is not readable: ${savedPage}`);
}
if (savedPage) {
  const batch = extractTLSProfiles(documentFor(fs.readFileSync(savedPage, "utf8")));
  equal(batch.profiles.length, 45, "saved-page record count");
  equal(batch.profiles[0].fullName, "Adam Wulf", "first saved-page record");
  equal(batch.profiles[4].fullName, "Anthony Santa Ana", "saved-page nested-label name");
  equal(batch.profiles[4].nickname, "Tony", "saved-page nickname");
  equal(batch.profiles[7].role, "K-12 Teacher", "saved-page role category");
  equal("title" in batch.profiles[7], false, "saved-page role stays role");
  equal(batch.profiles[8].title, "Program Manager & Wellness Captain", "saved-page title");
  equal(batch.profiles[44].fullName, "Ying Ma", "last saved-page record");
  equal(batch.profiles.filter((profile) => profile.photo).length, 44, "saved-page photo count");

  for (const profile of batch.profiles) compactTLSPhotoForHandoff(profile);
  const budget = fitTLSBatchToHandoffCap(batch);
  const payloadBytes = budget.byteSize;
  equal(budget.droppedPhotoIndexes.length, 0, "saved page keeps every photo");
  Object.assign(result, {
    savedRecords: batch.profiles.length,
    savedPhotos: batch.profiles.filter((profile) => profile.photo).length,
    savedPayloadBytes: payloadBytes,
    savedRemainingBytes: handoffCapBytes - payloadBytes,
  });
}
result.assertions = assertions;
console.log(JSON.stringify(result));
