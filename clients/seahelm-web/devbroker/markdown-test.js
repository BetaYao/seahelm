// markdown-test.js — the timeline's markdown subset, and that it stays inert.
//
// Run:  node devbroker/markdown-test.js
//
// Agent prose is untrusted text that ends up in innerHTML, so the escaping
// cases matter more than the formatting ones.
'use strict';

const { render } = require('../markdown.js');

let pass = 0, fail = 0;
const check = (name, got, want) => {
  const ok = typeof want === 'function' ? want(got) : got === want;
  if (ok) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name}\n       got:  ${got}\n       want: ${want}`); }
};

console.log('safety');
check('html is escaped', render('<img src=x onerror=alert(1)>'),
  '<p>&lt;img src=x onerror=alert(1)&gt;</p>');
check('javascript: link stays text', render('[x](javascript:alert(1))'),
  (h) => !h.includes('<a') && h.includes('[x](javascript:alert(1))'));
check('quotes in a url cannot break the attribute', render('[x](https://a.com/"onmouseover=1)'),
  (h) => !/href="[^"]*"on/.test(h));
check('code block content is escaped, not formatted', render('```\n<b>**x**</b>\n```'),
  '<pre><code>&lt;b&gt;**x**&lt;/b&gt;</code></pre>');

console.log('inline');
check('bold and code', render('**提交内容**：分支 `fix/a-b`'),
  '<p><strong>提交内容</strong>：分支 <code>fix/a-b</code></p>');
check('emphasis does not reach into code', render('`**not bold**`'),
  '<p><code>**not bold**</code></p>');
check('snake_case is not italic', render('run make_file_name and _real_'),
  '<p>run make_file_name and <em>real</em></p>');
check('bare url becomes a link, trailing punctuation excluded', render('PR：https://github.com/a/b/pull/1507。'),
  '<p>PR：<a href="https://github.com/a/b/pull/1507" target="_blank" rel="noopener noreferrer">https://github.com/a/b/pull/1507</a>。</p>');
check('url stops at chinese text', render('见https://x.com/a了'),
  (h) => h.includes('href="https://x.com/a"') && h.includes('</a>了'));
check('markdown link', render('[PR](https://x.com/p)'),
  '<p><a href="https://x.com/p" target="_blank" rel="noopener noreferrer">PR</a></p>');
check('single newlines are kept', render('one\ntwo'), '<p>one<br>two</p>');

console.log('blocks');
check('nested list', render('- a\n  - b\n  - c\n- d'),
  '<ul><li>a<ul><li>b</li><li>c</li></ul></li><li>d</li></ul>');
check('ordered list keeps its start', render('3. x\n4. y'), '<ol start="3"><li>x</li><li>y</li></ol>');
check('paragraph then list', render('two things:\n- a\n- b'),
  '<p>two things:</p><ul><li>a</li><li>b</li></ul>');
check('heading', render('## Summary'), '<h3>Summary</h3>');
check('table', render('| a | b |\n|---|---|\n| `1` | 2 |'),
  '<div class="md-table"><table><thead><tr><th>a</th><th>b</th></tr></thead>'
  + '<tbody><tr><td><code>1</code></td><td>2</td></tr></tbody></table></div>');
check('blockquote', render('> quoted **x**'), '<blockquote><p>quoted <strong>x</strong></p></blockquote>');
check('rule', render('a\n\n---\n\nb'), '<p>a</p><hr><p>b</p>');
check('unclosed fence runs to the end', render('```js\nconst a = 1'), '<pre><code>const a = 1</code></pre>');

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
