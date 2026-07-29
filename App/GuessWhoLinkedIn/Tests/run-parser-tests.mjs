import fs from "node:fs";
import { createRequire } from "node:module";

const domModulePath = process.argv[2];
if (!domModulePath) {
  throw new Error("usage: node run-parser-tests.mjs <DOM-module> [saved-TLS-page]");
}
const { parseHTML } = await import(domModulePath);
const require = createRequire(import.meta.url);
const {
  compactTLSPhotoForHandoff,
  extractProfile,
  extractRiceProfile,
  extractTLSProfiles,
} = require("../Resources/parse-profile.js");

const tlsURL = "https://tls26-s2-people.netlify.app/";
const handoffCapBytes = 8 * 1024 * 1024;
let assertions = 0;

function documentFor(html, url = tlsURL) {
  const { document } = parseHTML(html);
  Object.defineProperty(document, "location", {
    configurable: true,
    value: new URL(url),
  });
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

const result = { passed: true, assertions };
const savedPage = process.argv[3];
if (savedPage && fs.existsSync(savedPage)) {
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

  const handoff = {
    ...batch,
    profiles: batch.profiles.map((profile) =>
      compactTLSPhotoForHandoff({ ...profile })
    ),
  };
  const payloadBytes = Buffer.byteLength(JSON.stringify(handoff), "utf8");
  if (payloadBytes >= handoffCapBytes) {
    throw new Error(`payload ${payloadBytes} exceeds ${handoffCapBytes}`);
  }
  Object.assign(result, {
    records: batch.profiles.length,
    photos: batch.profiles.filter((profile) => profile.photo).length,
    payloadBytes,
    handoffCapBytes,
    remainingBytes: handoffCapBytes - payloadBytes,
  });
}
result.assertions = assertions;
console.log(JSON.stringify(result));
