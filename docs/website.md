# www.seahelm.dev

The marketing / architecture page lives in `site/`. Plain static HTML — no build
step, no framework, no dependencies. It ships in two languages:

| URL      | File                | `lang`    |
| -------- | ------------------- | --------- |
| `/`      | `site/index.html`   | `en`      |
| `/zh/`   | `site/zh/index.html`| `zh-Hans` |

Two real files, not one file with a runtime toggle: each language gets its own
URL to be indexed and shared under, and the Chinese page is written *as*
Chinese rather than mapped clause-by-clause off the English. They share
`site/style.css`, so a restyle is one edit rather than the same edit twice.

Every visitor lands on the page they asked for. There is no redirect on
`Accept-Language` — the masthead carries a switcher, and `hreflang` tells
search engines which page belongs to whom.

> Keep docs out of `site/`: every file in that directory is uploaded and served
> publicly.

## How it ships

Cloudflare Pages, **direct upload** project `seahelm`. There is deliberately
*no* Git integration on the Cloudflare side: `.github/workflows/deploy-site.yml`
is the only thing that publishes, so a deploy is a reviewable commit.

- push to `main` touching `site/**` → production
- pull request touching `site/**` → preview at `https://<branch>.seahelm.pages.dev`
- manual run → Actions → "Deploy site" → Run workflow

The workflow's first job is `scripts/check-site-parity.py`, and deploy waits on
it. See **Keeping the two pages in step** below.

Repo secrets used by the workflow: `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`,
`CLOUDFLARE_ZONE_ID`.

A production deploy purges the zone's edge cache afterwards. `site/_headers`
puts a long cache on `poster.jpg`, the two `og` cards and `tour-loop.mp4`, so
re-cutting the loop without the purge would stay invisible at the edge for a
day. `style.css` is deliberately left off that list.

## DNS

| Host               | Record                        | Serves                    |
| ------------------ | ----------------------------- | ------------------------- |
| `www.seahelm.dev`  | CNAME → `seahelm.pages.dev`   | the site (canonical)      |
| `seahelm.dev`      | CNAME → `seahelm.pages.dev`   | 301 → `www.seahelm.dev`   |
| `gw.seahelm.dev`   | CNAME → cloudflared tunnel    | unrelated; the edge stack |

The apex redirect is a zone **Redirect Rule** ("apex -> www (canonical)"), not
something in `site/` — `_redirects` in Cloudflare Pages matches on path only,
never on host.

To flip the canonical host to the apex: change the canonical, `og:url` and
`hreflang` values in the `<head>` of **both** `site/index.html` and
`site/zh/index.html`, update `site/sitemap.xml`, and invert that redirect rule.
The parity check enforces that the two heads agree about the alternate set.

## Files

| File                  | Why                                                     |
| --------------------- | ------------------------------------------------------- |
| `index.html`          | The English page. Diagrams are inline SVG.              |
| `zh/index.html`       | The Chinese page. Same structure, translated text.      |
| `style.css`           | Every rule, shared by both pages. Deliberately uncached in `_headers`: it has to stay in step with two HTML files, and a browser cache is not something the edge purge can reach. |
| `og.png` / `og.zh.png`| 1200×630 social cards. Regenerate: `scripts/build-og.sh` |
| `tour-loop.mp4`       | 7.5 s silent hero loop, autoplays. See below.           |
| `poster.jpg`          | Frame 0 of the loop; the reduced-motion still.          |
| `favicon.svg`         | The ship's wheel.                                       |
| `_redirects`          | `/install.sh` → the installer in this repo, repo links. |
| `_headers`            | `nosniff`, referrer policy, cache for static assets.    |
| `robots.txt`, `sitemap.xml` | Boilerplate.                                      |

Only the Google Fonts stylesheet is fetched from off-site; everything else,
diagrams included, ships from this directory. No CJK web font is loaded — one
is megabytes, and every platform this page runs on already has a good one, so
`style.css` names the system faces and lets Latin keep IBM Plex.

## Keeping the two pages in step

Two files means they can drift: a section added to one and forgotten in the
other, a diagram edited on one side only. `scripts/check-site-parity.py` is the
guard, and it runs in CI on every event including fork PRs.

It compares what must not differ and ignores the one thing that must:

| Compared                                             | Ignored                          |
| ---------------------------------------------------- | -------------------------------- |
| block elements in `<body>`, with `id` and `class`     | all text                         |
| the geometry of every SVG shape                       | inline tags: `code` `em` `a` `span` `tspan` … |
| the text inside `<code>` and `<pre>`                  | comments, marked `<span class="c">` |
| the set of `href`s                                    | the heads, which point at themselves |
| each page's `lang`, canonical and `hreflang` set      |                                  |

Inline elements are skipped because a translation is allowed to move a `<code>`
inside a sentence, and often has to. Identifiers are compared exactly, because
they do not translate and a typo is hardest to catch in the language its reader
is least likely to double-check.

Run it before pushing:

```sh
python3 scripts/check-site-parity.py
```

A failure names the node that diverged and the last one that matched.

### Editing the Chinese page

Translate text nodes; do not touch structure. Identifiers, commands, flags,
paths, branch names and product names stay in English — that is the house style
the READMEs already use. The SVG labels are placed at fixed coordinates, so a
label that grows can run out of its box; the parity check does not catch that,
so re-render and look.

## Editing

The page's numbers come from the codebase (layer file counts, the twelve
manifests in `Resources/Manifests/`, the hook event names, the control-socket
method names). If you change the architecture, change the page in the same PR.

Preview locally:

```sh
python3 -m http.server -d site 8080   # http://localhost:8080 and /zh/
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
