# GuessWho marketing website

A single-page static marketing site for the GuessWho app, built the same way
as the Mantra Moment site: **Hugo**, hand-written CSS, one small vanilla JS
file, no bundler, no npm, no framework, no web fonts, no analytics.

## Layout

```
website/
  hugo.toml                 Hugo config (single page; taxonomies/RSS/sitemap disabled)
  layouts/index.html        the entire page (Hugo template)
  layouts/_default/thanks.html
                            Netlify form success page
  content/thanks.md         success-page copy
  static/css/site.css       all styles (light + dark)
  static/js/memories.js     the one JS file (hero "how you met" rotator)
  static/images/            app-icon.png (site icon + brand mark) and screenshots
  public/                   Hugo output — gitignored, never committed
netlify.toml                (at the REPO ROOT) build + deploy config for Netlify
```

## Preview locally

From the **repo root**:

```sh
hugo server --source website
```

This starts a live-reload dev server (default http://localhost:1313).

## Build

From the **repo root**:

```sh
hugo --source website --gc --minify
```

Hugo writes the static output to `website/public/` (gitignored).

## Deploy

Netlify is connected to the git repository and builds on every push. Config
lives in `netlify.toml` at the repo root:

- `base = "website"`, `command = "hugo --gc --minify"`, `publish = "public"`
- `HUGO_VERSION = "0.165.0"` (non-extended is fine)
- deploy previews build with `--buildFuture --baseURL $DEPLOY_PRIME_URL`
- security headers (`X-Content-Type-Options`, `Referrer-Policy`, `X-Frame-Options`)

The custom domain is set in the **Netlify dashboard**, not in this repo — there
is intentionally no `CNAME` file, and `hugo.toml` uses relative URLs
(`baseURL = "/"`).

## Design notes

- **Light and dark mode** via `prefers-color-scheme` and CSS variables
  (GuessWho differs from Mantra here, which is dark-only). Palette:
  warm-coral accent + indigo, on a soft gradient ground.
- **Responsive**: single breakpoint at `42rem`; fluid type with `clamp()`.
- **System font stack** only (`-apple-system`, `BlinkMacSystemFont`, …).
- **Accessibility**: skip link; semantic `<section>`s with `aria-labelledby`;
  decorative images/icons hidden from assistive tech; the rotating hero card
  is `aria-live="off"`.
- **Motion**: the hero rotator pauses on hidden tabs and stops entirely under
  `prefers-reduced-motion: reduce`.
- Device screenshots sit inside a **pure-CSS phone frame** (no image chrome).

## Images

- Put image assets in `static/images/` and reference them with Hugo `relURL`, e.g.
  `{{ "images/app-icon.png" | relURL }}`.
- Give every `<img>` an explicit `width`/`height` to avoid layout shift.
- The site icon and brand mark is `app-icon.png`, a 512 × 512 export of the
  shipping iOS app icon (the OS applies its own corner mask; the site rounds
  the square PNG with CSS `border-radius` on `.brand-icon` / `.thanks-icon`).
  To refresh it, drop in a new square PNG export and resize to 512 × 512, e.g.
  from the `1024` app-icon export:

  ```sh
  sips -z 512 512 -s format png AppIcon-iOS-Default-1024@1x.png \
    --out website/static/images/app-icon.png
  ```

  Or export straight from the Icon Composer source with the tool Mantra uses:

  ```sh
  "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
    "App/GuessWho/AppIcon.icon" --export-image \
    --output-file website/static/images/app-icon.png \
    --platform macOS --rendition Default --width 512 --height 512 --scale 1
  ```

- The iOS app screenshots are real iPhone 17 Simulator captures made with AXe.
  Each screen has a 1206 × 2622 light and dark image; `<picture>` selects the
  one that matches the visitor's system appearance.
- The Mac screenshots are real GuessWho for Mac window captures with their own
  macOS chrome and drop shadow, exported as transparent PNGs (1600 px wide,
  natural aspect ratio — no crop). Each of the two slots has a light and dark
  image: `static/images/mac-people-{light,dark}.png` (the Organizations view)
  and `static/images/mac-contact-{light,dark}.png` (a contact in context).
  `<picture>` selects the one matching the visitor's system appearance, and
  Hugo replaces that slot's labeled placeholder once the light image is present.

## TestFlight signup

The `testflight-signup` form in `layouts/index.html` uses Netlify Forms. It
collects a required email address, includes a honeypot field, and redirects to
the no-index `/thanks/` page after submission. Netlify detects the form from
the generated HTML during deploy; there is no function or server to configure.

## Still needed from Adam

- The custom domain (set in the Netlify dashboard).
