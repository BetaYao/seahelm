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

Repo secrets used by the workflow: `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`.

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
