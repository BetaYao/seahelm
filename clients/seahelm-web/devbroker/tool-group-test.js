// tool-group-test.js — a run of tool calls folds to one line, and nothing else moves.
//
// Run:  node devbroker/tool-group-test.js
'use strict';

const { fold } = require('../tool-group.js');

let pass = 0, fail = 0;
const check = (ok, name, extra = '') => {
  if (ok) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name} ${extra}`); }
};
const tool = (seq, over = {}) => Object.assign(
  { seq, kind: 'tool', tool: 'Bash', detail: `cmd ${seq}` }, over);
const said = (seq) => ({ seq, kind: 'assistant', text: `line ${seq}` });
const kinds = (items) => items.map(i => i.kind).join(',');

console.log('tool group');

{
  const items = fold([said(1), tool(2), tool(3), tool(4), said(5)]);
  check(kinds(items) === 'row,tools,row', 'a run between two replies folds', kinds(items));
  check(items[1].rows.length === 3, 'the calls are kept for opening', String(items[1].rows.length));
}

{
  // One call is already one line; making it click-to-open costs a tap to learn nothing.
  const items = fold([said(1), tool(2), said(3)]);
  check(kinds(items) === 'row,row,row', 'a lone call is left alone', kinds(items));
}

{
  // What the agent said in the middle is what explains the calls either side.
  const items = fold([tool(1), tool(2), said(3), tool(4), tool(5)]);
  check(kinds(items) === 'tools,row,tools', 'a reply between runs splits them', kinds(items));
}

{
  const items = fold([]);
  check(items.length === 0, 'nothing folds to nothing');
}

{
  const [g] = fold([tool(1), tool(2), tool(3)]);
  // Keyed by where the run starts: a run grows while the agent works, and an
  // opened group must not shut itself on the next call.
  check(g.key === 1, 'keyed by the first call', String(g.key));
  check(g.seq === 3, 'anchored at the newest call', String(g.seq));
}

{
  const [g] = fold([tool(1), tool(2)]);
  check(g.tool === 'Bash', 'one tool name is the label', g.tool);
  check(g.detail === 'cmd 2', 'the newest call is what it shows', g.detail);
}

{
  // Naming one of the kinds up front would say the run was all of that, and
  // counting the kinds there ("3 tools ×5") puts two different numbers on a line.
  const [g] = fold([tool(1), tool(2, { tool: 'Read' }), tool(3, { tool: 'Grep', detail: 'needle' })]);
  check(g.tool === 'Tools', 'a mixed run is labelled Tools', g.tool);
  check(g.detail === 'Grep needle', 'and names the newest call in the detail', g.detail);
}

{
  // Tools without arguments report their own name as detail, which would only
  // repeat the label.
  const [g] = fold([tool(1), tool(2, { detail: 'Bash' })]);
  check(g.detail === '', 'detail that repeats the name is dropped', JSON.stringify(g.detail));
}

{
  // Server-side coalescing already folded identical neighbours into a `count`,
  // so the line reports calls made, not rows on screen.
  const [g] = fold([tool(1, { count: 3 }), tool(2), tool(3, { count: 2 })]);
  check(g.count === 6, 'counts are summed, not rows', String(g.count));
}

{
  // Folding is for saving room, not for hiding that something broke.
  const [g] = fold([tool(1), tool(2, { is_error: true }), tool(3)]);
  check(g.isError === true, 'a failure inside colours the line', String(g.isError));
  const [clean] = fold([tool(1), tool(2)]);
  check(clean.isError === false, 'a clean run is not marked', String(clean.isError));
}

{
  // Rows that are not tools pass through untouched, whatever they are.
  const items = fold([{ seq: 1, kind: 'status', status: 'running' },
                      { seq: 2, kind: 'user', text: 'go' },
                      { seq: 3, kind: 'thinking', text: 'hm' }]);
  check(kinds(items) === 'row,row,row', 'other kinds are untouched', kinds(items));
  check(items[1].msg.text === 'go', 'and carry their message', items[1].msg.text);
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
