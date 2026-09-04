#!/usr/bin/env python3
"""Structural parity between the English and Chinese pages of www.seahelm.dev.

The two pages are separate files on purpose: each gets a real URL, a real
`lang`, and prose written *as* that language rather than mapped word for word
from the other. The cost of that choice is drift — a section added to one and
forgotten in the other, a diagram edited on one side only.

This is the guard. It compares everything about the two files that must not
differ, and ignores the one thing that must:

  structure   the sequence of block elements with their id and class, plus the
              geometry of every SVG shape. Inline elements (code, em, a, span,
              tspan …) are skipped: a translation is allowed to move a <code>
              inside a sentence, and often has to.
  code        the text inside <code> and <pre>, in order. Identifiers, commands
              and flags are not translatable, and a typo'd one is worse in the
              language its reader is less likely to double-check. Comments —
              the page marks them <span class="c"> — are prose and are skipped.
  links       the set of hrefs. A link present on one page and not the other is
              a page that says something the other does not.

Only <body> is compared. The heads differ by design: each page's canonical,
og:url and og:image point at itself. Those are checked by name instead, at the
bottom.

Run: python3 scripts/check-site-parity.py
"""
import sys
from html.parser import HTMLParser

PAGES = [("site/index.html", "en"), ("site/zh/index.html", "zh")]

# Elements that may legitimately be reordered or reshaped by a translator.
INLINE = {"code", "em", "b", "strong", "i", "a", "span", "tspan", "br",
          "sup", "sub", "abbr", "small", "u", "s"}
# Content that is not page structure at all.
SKIP = {"script", "style"}
# Attributes that place or shape a node. Text differs between the pages; where
# that text sits does not.
GEOM = ("x", "y", "width", "height", "cx", "cy", "r", "rx", "ry",
        "x1", "y1", "x2", "y2", "d", "points", "viewBox", "transform",
        "text-anchor", "marker-end", "stroke-dasharray", "fill", "stroke",
        "stroke-width", "href", "src", "type", "rel", "colspan", "rowspan",
        "style")


class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=False)
        self.structure = []
        self.code = []
        self.links = set()
        self._skip = 0
        self._grab = 0
        self._comment = 0
        self._buf = []
        self._in_body = False

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "body":
            self._in_body = True
        if tag in SKIP:
            self._skip += 1
            return
        if self._skip or not self._in_body:
            return
        if "href" in a:
            self.links.add(a["href"])
        # The page marks a comment inside a code block with class "c". It is
        # prose written for a reader, so it translates like prose.
        if tag == "span" and "c" in a.get("class", "").split():
            self._comment += 1
        if tag in ("code", "pre"):
            self._grab += 1
            self._buf = []
        if tag not in INLINE:
            sig = [tag, a.get("id", ""), a.get("class", "")]
            sig += ["%s=%s" % (k, a[k]) for k in GEOM if k in a]
            self.structure.append("|".join(sig))

    def handle_endtag(self, tag):
        if tag in SKIP:
            self._skip = max(0, self._skip - 1)
            return
        if tag == "span" and self._comment:
            self._comment -= 1
            return
        if tag in ("code", "pre") and self._grab:
            self._grab -= 1
            self.code.append(" ".join("".join(self._buf).split()))
            self._buf = []

    def _keep(self):
        return self._grab and not self._skip and not self._comment

    def handle_data(self, data):
        if self._keep():
            self._buf.append(data)

    def handle_entityref(self, name):
        if self._keep():
            self._buf.append("&%s;" % name)

    def handle_charref(self, name):
        if self._keep():
            self._buf.append("&#%s;" % name)


def load(path):
    p = Page()
    with open(path, encoding="utf-8") as fh:
        p.feed(fh.read())
    return p


def diff(kind, a, b, an, bn, problems):
    """Report the first divergence in two ordered lists, with its neighbours."""
    for i in range(max(len(a), len(b))):
        x = a[i] if i < len(a) else None
        y = b[i] if i < len(b) else None
        if x == y:
            continue
        problems.append(
            "%s diverges at #%d of %d/%d\n"
            "  %-14s %s\n  %-14s %s\n"
            "  (previous match: %s)"
            % (kind, i, len(a), len(b), an + ":", x, bn + ":", y,
               a[i - 1] if i else "<start of document>")
        )
        return
    if len(a) != len(b):
        problems.append("%s: %s has %d, %s has %d"
                        % (kind, an, len(a), bn, len(b)))


def main():
    try:
        pages = [(name, lang, load(name)) for name, lang in PAGES]
    except OSError as exc:
        print("cannot read a page: %s" % exc, file=sys.stderr)
        return 2

    (an, _, a), (bn, _, b) = pages
    problems = []
    diff("structure", a.structure, b.structure, an, bn, problems)
    diff("code/pre", a.code, b.code, an, bn, problems)

    only_a = sorted(a.links - b.links)
    only_b = sorted(b.links - a.links)
    if only_a or only_b:
        problems.append("links differ\n  only in %s: %s\n  only in %s: %s"
                        % (an, only_a or "-", bn, only_b or "-"))

    # A page that forgot its own language, or points its canonical at the other.
    for name, lang, _ in pages:
        with open(name, encoding="utf-8") as fh:
            head = fh.read(4000)
        want = 'lang="zh-Hans"' if lang == "zh" else 'lang="en"'
        if "<html %s>" % want not in head:
            problems.append("%s: <html> is not %s" % (name, want))
        canon = "https://www.seahelm.dev/zh/" if lang == "zh" else "https://www.seahelm.dev/"
        if 'rel="canonical" href="%s"' % canon not in head:
            problems.append("%s: canonical is not %s" % (name, canon))
        for tag in ('hreflang="en"', 'hreflang="zh-Hans"', 'hreflang="x-default"'):
            if tag not in head:
                problems.append("%s: missing alternate %s" % (name, tag))

    if problems:
        print("site parity FAILED\n")
        for p in problems:
            print(p + "\n")
        return 1
    print("site parity ok — %d structural nodes, %d code spans, %d links"
          % (len(a.structure), len(a.code), len(a.links)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
