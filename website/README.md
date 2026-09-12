# GuessWho marketing website

A single-page static marketing site for the GuessWho app, built the same way
as the Mantra Moment site: **Hugo**, hand-written CSS, one small vanilla JS
file, no bundler, no npm, no framework, no web fonts, no analytics.

## Layout

```
website/
  hugo.toml                 Hugo config (single page; taxonomies/RSS/sitemap disabled)
  layouts/index.html        the entire page (Hugo template)
  static/css/site.css       all styles (light + dark)
  static/js/memories.js     the one JS file (hero "how you met" rotator)
  static/images/            app-icon.png (favicon + hero) and screenshots
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

- Put PNGs in `static/images/` and reference them with Hugo `relURL`, e.g.
  `{{ "images/app-icon.png" | relURL }}`.
- Give every `<img>` an explicit `width`/`height` to avoid layout shift.
- Export the app icon from the Xcode source (same tool Mantra uses):

  ```sh
  "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
    "App/GuessWho/AppIcon.icon" --export-image \
    --output-file website/static/images/app-icon.png \
    --platform macOS --rendition Default --width 512 --height 512 --scale 1
  ```

- The app screenshots are captured from the iOS Simulator. Drop the PNGs in
  `static/images/` and replace the `.shot-placeholder` blocks in
  `layouts/index.html` with `<img>` tags (portrait shots are 1206 × 2622).

## Still needed from Adam

- Real TestFlight / App Store link (set `ctaURL` / `ctaLabel` in `hugo.toml`).
- The custom domain (set in the Netlify dashboard).
