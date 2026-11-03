#!/usr/bin/env bash
# imessage-bot-probe.sh — can seahelm talk iMessage through a second macOS user?
#
# The idea under test: your own macOS user keeps your own Apple ID in Messages,
# and a second macOS user (default `seahelm-bot`) is signed into a separate
# Apple ID for the bot. Seahelm, running as you, reaches that user's Messages
# through `ssh <bot>@localhost imsg …` — imsg reads the bot's chat.db and sends
# through the bot's Messages.app. Nothing here changes either account.
#
# Before running, by hand (only you can do these):
#   1. System Settings ▸ Users & Groups: add a user (default name seahelm-bot).
#   2. Log in as it once, open Messages, sign in with the bot's Apple ID.
#   3. As the bot: brew install steipete/tap/imsg   (or rely on a shared Homebrew)
#   4. System Settings ▸ Users & Groups ▸ (i) Fast User Switching: on.
#      Switch back to yourself and leave the bot logged in, in the background.
#   5. System Settings ▸ General ▸ Sharing ▸ Remote Login: on (at least for the bot).
#   6. Put your public key in the bot's ~/.ssh/authorized_keys
#      (e.g. ssh-copy-id seahelm-bot@localhost).
#   7. System Settings ▸ Privacy & Security ▸ Full Disk Access: add
#      /usr/libexec/sshd-keygen-wrapper, so imsg run over SSH can read chat.db.
#
# Usage:
#   scripts/imessage-bot-probe.sh --to <your iMessage phone or email> [--user seahelm-bot] [--wait 180]
#
# The script sends one test message to --to, then watches the bot's Messages
# while you reply from your Watch (dictation) and tap 👍 on the test message.
set -uo pipefail

BOT=seahelm-bot
TO=""
WAIT=180

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to) TO="${2:-}"; shift 2 ;;
    --user) BOT="${2:-}"; shift 2 ;;
    --wait) WAIT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$TO" ]] || { echo "usage: $0 --to <your iMessage phone or email> [--user $BOT] [--wait $WAIT]" >&2; exit 2; }

declare -a RESULTS=()
pass() { RESULTS+=("PASS  $1"); printf '  \033[32mok\033[0m    %s\n' "$1"; }
fail() { RESULTS+=("FAIL  $1"); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; }
warn() { RESULTS+=("WARN  $1"); printf '  \033[33mwarn\033[0m  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; }
summary() {
  echo; echo "── summary ──"
  printf '%s\n' "${RESULTS[@]}"
}
stop() { summary; exit 1; }

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)
SSH=(ssh "${SSH_OPTS[@]}" "$BOT@localhost")

echo "── preflight (bot user: $BOT) ──"

if dscl . -read "/Users/$BOT" UniqueID >/dev/null 2>&1; then pass "user $BOT exists"
else fail "user $BOT exists" "create it in System Settings ▸ Users & Groups"; stop; fi

if pgrep -u "$BOT" loginwindow >/dev/null 2>&1; then pass "$BOT has a GUI session (logged in, may be in the background)"
else fail "$BOT has a GUI session" "log in as $BOT, then use Fast User Switching to come back without logging it out"; stop; fi

if pgrep -u "$BOT" -x Messages >/dev/null 2>&1; then pass "Messages is running in $BOT's session"
else warn "Messages is not running in $BOT's session" "imsg will try to launch it; if sends fail, open Messages as $BOT once and switch back"; fi

if nc -z -G 2 127.0.0.1 22 >/dev/null 2>&1; then pass "Remote Login (ssh) is listening"
else fail "Remote Login (ssh) is listening" "System Settings ▸ General ▸ Sharing ▸ Remote Login"; stop; fi

if "${SSH[@]}" true >/dev/null 2>&1; then pass "key-based ssh into $BOT@localhost"
else fail "key-based ssh into $BOT@localhost" "ssh-copy-id $BOT@localhost   (asks for $BOT's password once)"; stop; fi

IMSG=$("${SSH[@]}" 'for p in /opt/homebrew/bin/imsg /usr/local/bin/imsg "$HOME/.local/bin/imsg"; do [ -x "$p" ] && { echo "$p"; exit 0; }; done; command -v imsg' 2>/dev/null | tail -1)
if [[ -n "$IMSG" ]]; then pass "imsg found for $BOT: $IMSG ($("${SSH[@]}" "$IMSG --version" 2>/dev/null | head -1))"
else fail "imsg installed for $BOT" "as $BOT: brew install steipete/tap/imsg"; stop; fi

CHATS_ERR=$(mktemp); CHATS=$("${SSH[@]}" "$IMSG chats --limit 5 --json" 2>"$CHATS_ERR"); RC=$?
if [[ $RC -eq 0 ]]; then
  pass "imsg can read $BOT's chat.db over ssh"
  LOGINS=$(printf '%s\n' "$CHATS" | python3 -I -c '
import sys, json
seen = set()
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: c = json.loads(line)
    except ValueError: continue
    if c.get("account_login"): seen.add(c["account_login"])
print(", ".join(sorted(seen)))')
  if [[ -n "$LOGINS" ]]; then echo "        account(s) seen in $BOT's chats: $LOGINS  ← should be the bot's Apple ID, not yours"
  else echo "        no chats yet, so the signed-in account can't be shown — the send below will create one"; fi
else
  fail "imsg can read $BOT's chat.db over ssh" "$(head -2 "$CHATS_ERR" | tr '\n' ' ')"
  echo "        likely fix: Full Disk Access for /usr/libexec/sshd-keygen-wrapper, then rerun"
  rm -f "$CHATS_ERR"; stop
fi
rm -f "$CHATS_ERR"

echo; echo "── 1. send from the bot ──"
STAMP=$(date +%H:%M:%S)
PROBE="seahelm probe $STAMP — reply to this by voice, then tap 👍 on it"
printf -v QTO '%q' "$TO"; printf -v QTEXT '%q' "$PROBE"
SEND_OUT=$("${SSH[@]}" "$IMSG send --to $QTO --text $QTEXT --service imessage --json" 2>&1); RC=$?
if [[ $RC -eq 0 ]] && grep -q '"sent"' <<<"$SEND_OUT"; then pass "imsg send reports sent ($SEND_OUT)"
else fail "imsg send" "$SEND_OUT"; stop; fi

read -r -p "  Did \"seahelm probe $STAMP\" arrive on your phone/Watch, from the bot's Apple ID (not from yourself)? [y/n] " ans
[[ "$ans" == [yY]* ]] && pass "probe arrived, from the bot's identity" || fail "probe arrived, from the bot's identity" "check Messages as $BOT (Settings ▸ iMessage: signed in, the address enabled)"

echo; echo "── 2 & 3. receive in the bot ──"
LOG=$(mktemp)
# -tt so the remote imsg gets a hangup when this side goes away.
ssh "${SSH_OPTS[@]}" -tt "$BOT@localhost" "$IMSG watch --json --reactions --debounce 250ms" >"$LOG" 2>/dev/null &
WATCH_PID=$!
trap 'kill $WATCH_PID 2>/dev/null; rm -f "$LOG"' EXIT
sleep 2
echo "  Now, on your Watch:"
echo "    a) reply to the probe by dictation (any sentence, mixing Chinese and English is a good test)"
echo "    b) long-press the probe message and tap 👍"
echo "  Waiting up to ${WAIT}s …"

GOT_MSG=""; GOT_REACT=""
for ((i = 0; i < WAIT; i++)); do
  STATE=$(python3 -I - "$LOG" <<'PY'
import sys, json
msg = react = ""
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip().strip("\r")
    if not line.startswith("{"): continue
    try: m = json.loads(line)
    except ValueError: continue
    if m.get("is_from_me"): continue
    if m.get("is_reaction"):
        react = "%s %s" % (m.get("reaction_type") or m.get("reaction_emoji") or "?", "added" if m.get("is_reaction_add", True) else "removed")
    elif (m.get("text") or "").strip():
        msg = (m.get("text") or "").strip().replace("\t", " ")
print(msg + "\t" + react)
PY
)
  GOT_MSG=${STATE%%$'\t'*}; GOT_REACT=${STATE#*$'\t'}
  [[ -n "$GOT_MSG" && -n "$GOT_REACT" ]] && break
  sleep 1
done

[[ -n "$GOT_MSG" ]] && pass "bot received your reply: \"$GOT_MSG\"" || fail "bot received your reply" "nothing inbound within ${WAIT}s — is Messages in $BOT's background session receiving at all?"
[[ -n "$GOT_REACT" ]] && pass "bot received your tapback: $GOT_REACT" || fail "bot received your tapback" "if the reply arrived but this did not, tapbacks need another route"

summary
