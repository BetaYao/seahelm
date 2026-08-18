# vendor/

`ghostty-web` 0.4.0 — vendored from npm, not a CDN: the gateway serves this
directory as a same-origin static site and cannot reach外部主机.

`ghostty-web.js` inlines its 416KB wasm as a `data:` URL, so the two files here
are the whole dependency. `__vite-browser-external-*.js` is a build stub for a
Node builtin the bundle never actually calls.

Refresh with:

    npm pack ghostty-web@<version>   # then copy dist/ghostty-web.js + the stub
