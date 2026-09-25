// What the one button beside the composer does right now.
//
// It used to be three things in three places: a Send button, an Interrupt in
// the head, and a status line above the composer saying "Running 2m". On a
// phone that is two rows of furniture for a state the button itself could just
// wear — and the head had run out of room for a fourth control anyway.
//
// So Send carries the status and absorbs the interrupt. The precedence is the
// point: **typed text always sends.** An agent is nearly always busy while you
// are typing at it, so letting "busy" win would make the button refuse the
// message you just wrote. Stopping is what the button means only when there is
// nothing to send — which is also exactly when you reach for it.
//
// Nothing here knows about the DOM; `status` is whatever normStatus produced.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.SeahelmComposerAction = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // Esc at a waiting prompt is "never mind", so it is stoppable too. `failed`
  // is not: there is nothing still going to stop, and the button would be
  // offering to interrupt a pane that already gave up.
  const STOPPABLE = { running: true, waiting: true };

  /**
   * @param {object} o
   * @param {boolean} o.hasText   the composer holds something to send
   * @param {string}  o.status    the selected pane's status, already normalised
   * @param {boolean} o.ready     a pane is selected and the socket is up
   * @returns {'send'|'stop'|'none'}
   */
  function composerAction(o) {
    if (!o || !o.ready) return 'none';
    if (o.hasText) return 'send';
    return STOPPABLE[o.status] ? 'stop' : 'none';
  }

  // What is on the other end of the composer. The Mac reports a pane's
  // `agent_type`, and drops it back to a shell type when the agent exits, so a
  // pane is an agent only while one of these is running in it. Anything else —
  // `unknown` (never had one), `shellCommand`, `npm` and the other jobs — is a
  // terminal, and text sent there runs as a command.
  const AGENT_LABELS = {
    claudeCode: 'Claude Code', codex: 'Codex', openCode: 'OpenCode', gemini: 'Gemini',
    cline: 'Cline', goose: 'Goose', amp: 'Amp', aider: 'Aider', cursor: 'Cursor',
    kiro: 'Kiro', pi: 'Pi',
  };

  /** @returns {{kind:'agent'|'shell', label:string}} */
  function paneKind(agentType) {
    const label = AGENT_LABELS[agentType];
    return label ? { kind: 'agent', label } : { kind: 'shell', label: 'Terminal' };
  }

  return { composerAction, STOPPABLE, paneKind, AGENT_LABELS };
});
