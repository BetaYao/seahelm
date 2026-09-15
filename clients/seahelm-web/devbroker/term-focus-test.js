// term-focus-test.js — chrome clicks must not steal the terminal caret.
//
// Run:  node devbroker/term-focus-test.js
//
// In a browser every <button> is focusable. Click the list, a chip, or a
// shortcut, and xterm's helper textarea loses the IME — the pane still looks
// selected. The Mac never has this split because Ghostty is first responder.
'use strict';

const { shouldRestoreTerminal, install } = require('../term-focus.js');

let pass = 0, fail = 0;
const check = (ok, name, extra = '') => {
  if (ok) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name} ${extra}`); }
};

console.log('term focus');

check(shouldRestoreTerminal(null) === true, 'nothing focused → restore');
check(shouldRestoreTerminal({ tagName: 'BODY' }) === true, 'body → restore');
check(shouldRestoreTerminal({ tagName: 'BUTTON' }) === true, 'a button is not an input');
check(shouldRestoreTerminal({ tagName: 'DIV' }) === true, 'a row / chip container is not an input');
check(shouldRestoreTerminal({ tagName: 'INPUT', type: 'text' }) === false, 'a text field keeps the caret');
check(shouldRestoreTerminal({ tagName: 'INPUT', type: 'number' }) === false, 'so does a numeric field');
check(shouldRestoreTerminal({ tagName: 'TEXTAREA' }) === false, 'and a textarea (pairing / IME)');
check(shouldRestoreTerminal({ tagName: 'SELECT' }) === false, 'and a select');
check(shouldRestoreTerminal({ tagName: 'DIV', isContentEditable: true }) === false,
      'contenteditable keeps the caret');
check(shouldRestoreTerminal({ tagName: 'INPUT', type: 'hidden' }) === true,
      'a hidden input is not a place to type');
check(shouldRestoreTerminal({ tagName: 'INPUT', type: 'button' }) === true,
      'an input-as-button is chrome');

{
  let restored = 0;
  let prevented = false;
  let tabindex;
  const listeners = {};
  const button = {
    tagName: 'BUTTON',
    setAttribute(name, value) { if (name === 'tabindex') tabindex = value; },
  };
  const doc = {
    activeElement: button,
    addEventListener(type, fn) {
      (listeners[type] = listeners[type] || []).push(fn);
    },
  };
  const later = [];
  install(doc, () => { restored++; }, { setTimer: (fn) => later.push(fn) });

  const ev = {
    target: { closest: () => button },
    preventDefault() { prevented = true; },
  };
  for (const fn of listeners.mousedown || []) fn(ev);
  check(prevented, 'mousedown on chrome does not move focus');
  check(tabindex === '-1', 'and the control leaves the tab order');

  for (const fn of listeners.click || []) fn(ev);
  check(restored === 0, 'restore waits until the click handler finishes');
  for (const fn of later) fn();
  check(restored === 1, 'then the terminal is given the keyboard back');
}

{
  let restored = 0;
  const listeners = {};
  const input = { tagName: 'INPUT', type: 'text' };
  const doc = {
    activeElement: input,
    addEventListener(type, fn) {
      (listeners[type] = listeners[type] || []).push(fn);
    },
  };
  const later = [];
  install(doc, () => { restored++; }, { setTimer: (fn) => later.push(fn) });
  for (const fn of listeners.click || []) fn({});
  for (const fn of later) fn();
  check(restored === 0, 'does not steal the caret from a real input');
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
