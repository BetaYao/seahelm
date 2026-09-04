# www.seahelm.dev

The marketing / architecture page lives in `site/`. Plain static HTML — no build
step, no framework, no dependencies. `site/index.html` is the whole site.

> Keep docs out of `site/`: every file in that directory is uploaded and served
> publicly.

## How it ships

Cloudflare Pages, **direct upload** project `seahelm`. There is deliberately
*no* Git integration on the Cloudflare side: `.github/workflows/deploy-site.yml`
is the only thing that publishes, so a deploy is a reviewable commit.

- push to `main` touching `site/**` → production
- pull request touching `site/**` → preview at `https://<branch>.seahelm.pages.dev`
- manual run → Actions → "Deploy site" → Run workflow

Repo secrets used by the workflow: `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`,
`CLOUDFLARE_ZONE_ID`.

A production deploy purges the zone's edge cache afterwards. `site/_headers`
puts a long cache on `poster.jpg`, `og.png` and `tour-loop.mp4`, so re-cutting
the loop without the purge would stay invisible at the edge for a day.

## DNS

| Host               | Record                        | Serves                    |
| ------------------ | ----------------------------- | ------------------------- |
| `www.seahelm.dev`  | CNAME → `seahelm.pages.dev`   | the site (canonical)      |
| `seahelm.dev`      | CNAME → `seahelm.pages.dev`   | 301 → `www.seahelm.dev`   |
| `gw.seahelm.dev`   | CNAME → cloudflared tunnel    | unrelated; the edge stack |

The apex redirect is a zone **Redirect Rule** ("apex -> www (canonical)"), not
something in `site/` — `_redirects` in Cloudflare Pages matches on path only,
never on host.

To flip the canonical host to the apex: change the canonical/og:url values in
the `<head>` of `site/index.html`, and invert that redirect rule.

## Files

| File                  | Why                                                     |
| --------------------- | ------------------------------------------------------- |
| `index.html`          | The page. CSS inline, diagrams inline SVG.              |
| `og.png`              | 1200×630 social card. Regenerate: `scripts/build-og.sh` |
| `tour-loop.mp4`       | 7.5 s silent hero loop, autoplays. See below.           |
| `poster.jpg`          | Frame 0 of the loop; the reduced-motion still.          |
| `favicon.svg`         | The ship's wheel.                                       |
| `_redirects`          | `/install.sh` → the installer in this repo, repo links. |
| `_headers`            | `nosniff`, referrer policy, cache for static assets.    |
| `robots.txt`, `sitemap.xml` | Boilerplate.                                      |

Only the Google Fonts stylesheet is fetched from off-site; everything else,
diagrams included, ships inside `index.html`.

## Editing

The page's numbers come from the codebase (layer file counts, the twelve
manifests in `Resources/Manifests/`, the hook event names, the control-socket
method names). If you change the architecture, change the page in the same PR.

Preview locally:

```sh
python3 -m http.server -d site 8080   # http://localhost:8080
```

## The hero loop

`site/tour-loop.mp4` is a 7.5-second silent excerpt cropped to the seahelm
window plus the Island pill above it. It autoplays and loops; clicking it opens
the full 47-second tour on YouTube.

The master recording is **not in this repo** — it is ~76 MB of 1920×1080 h264
(`Recording 2026-08-21 at 20.48.15.mp4`). Keep it with your raw footage and
re-encode with:

```sh
scripts/build-loop.sh <recording.mp4> [start_seconds] [duration]
```

The crop in that script is measured against that particular recording; re-measure
it if you shoot new footage. Two things the current segment was chosen for: it
sits between the screen-recorder's auto-zooms (so the framing never jumps), and
it starts and ends on the same window state, so the loop point does not jar.

Do not encode a WebM alongside it — VP9 came out *larger* than x264 on this
footage. `assets/tour.gif` is 640×360 and stays a README asset; it is far too
low-resolution for the page.

Reduced-motion visitors never download the mp4: the markup carries no
`autoplay` attribute, and the script only calls `play()` when
`prefers-reduced-motion` is not set. They see `poster.jpg`, which is frame 0.
