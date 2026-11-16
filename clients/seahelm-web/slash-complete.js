// Completing an agent's slash commands in the timeline composer.
//
// The list comes from seahelm-core (`agent.commands`): the agent's built-ins
// and every command, skill and plugin command the user added. Nothing here
// runs a command — a completed `/compact` is sent into the pane like any other
// message. What this adds is knowing what there is, and what sending it does:
// a picker such as `/model` opens in the terminal, which the timeline cannot
// show, so the menu says so before you send it.
//
// No DOM here; index.html draws the menu.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.SeahelmSlashComplete = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  /**
   * The command name being typed, without its slash: only while the message
   * starts with `/` and the caret is still in that first word.
   * @returns {string|null}
   */
  function query(text, caret) {
    if (typeof text !== 'string' || text[0] !== '/') return null;
    const at = typeof caret === 'number' ? caret : text.length;
    const word = text.slice(1).split(/\s/)[0];
    if (at < 1 || at > word.length + 1) return null;
    return word;
  }

  /**
   * The commands that fit `q`, best first: names starting with it, then a
   * plugin command's own part starting with it (`tdd` finds
   * `mattpocock-skills:tdd`), then names containing it, then — from four
   * letters on, so `/mod` is not `/vim` for its "mode" — descriptions
   * containing it.
   */
  function match(commands, q, limit) {
    const max = limit || 8;
    const needle = String(q || '').toLowerCase();
    const scored = [];
    for (const c of commands || []) {
      const name = String(c.name || '').toLowerCase();
      const own = name.includes(':') ? name.slice(name.indexOf(':') + 1) : name;
      let rank = -1;
      if (name.startsWith(needle)) rank = 0;
      else if (own.startsWith(needle)) rank = 1;
      else if (name.includes(needle)) rank = 2;
      else if (needle.length >= 4 && String(c.description || '').toLowerCase().includes(needle)) rank = 3;
      if (rank >= 0) scored.push({ c, rank, name });
    }
    scored.sort((a, b) => a.rank - b.rank
      || (a.c.source === 'builtin' ? 0 : 1) - (b.c.source === 'builtin' ? 0 : 1)
      || a.name.length - b.name.length
      || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    return scored.slice(0, max).map(s => s.c);
  }

  /** The message with its first word replaced by the command, and a space
   *  after it for the arguments. */
  function apply(text, command) {
    const rest = String(text || '').replace(/^\/\S*/, '').replace(/^\s+/, '');
    return `/${command.name} ${rest}`;
  }

  /** What sending it does, when that is not just a turn in the timeline. */
  function kindNote(kind) {
    switch (kind) {
      case 'interactive': return 'opens in the terminal';
      case 'info': return 'output in the terminal';
      case 'session': return 'ends or replaces the conversation';
      default: return '';
    }
  }

  return { query, match, apply, kindNote };
});
