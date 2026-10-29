#!/usr/bin/env bash
# test_later.sh: how `later` decides a claude job was delivered, from the relay's stream-json record (the shape a real
# `claude -p --output-format stream-json` relay writes). Changes nothing on the machine. Run: ./test_later.sh
set -uo pipefail
LATER="$(cd "$(dirname "$(realpath "$0")")" && pwd)/bin/later"
FAILS=0

call() {     # id to message
    jq -nc --arg id "$1" --arg to "$2" --arg m "$3" \
        '{type: "assistant", message: {content: [{type: "tool_use", name: "SendMessage", id: $id, input: {to: $to, message: $m}}]}}'
}
result() {   # id success [is_error]
    jq -nc --arg id "$1" --argjson ok "$2" --argjson err "${3:-null}" \
        '{type: "user", message: {content: [{type: "tool_result", tool_use_id: $id, is_error: $err,
          content: [{type: "text", text: ({success: $ok, message: "x"} | tojson)}]}]}}'
}
expect() {   # label want stream
    local got
    got="$("$LATER" _sent sess "Queued message from the user (later, t): continue" <<<"$3")"
    if [ "$got" = "$2" ]; then echo "ok    $1"; else echo "FAIL  $1: got $got, want $2"; FAILS=$((FAILS + 1)); fi
}

M="Queued message from the user (later, t): continue"
expect "the exact text, answered with success"   exact   "$(call t1 sess "$M"; result t1 true)"
expect "a shortened text (what happened 22:40)"  altered "$(call t1 sess continue; result t1 true)"
expect "the right text to another session"       altered "$(call t1 other "$M"; result t1 true)"
expect "a failed result"                         none    "$(call t1 sess "$M"; result t1 false)"
expect "a result reported as an error"           none    "$(call t1 sess "$M"; result t1 true true)"
expect "a result for some other call"            none    "$(call t1 sess "$M"; result t2 true)"
expect "a failed try, then a good one"           exact   "$(call t1 sess "$M"; result t1 false; call t2 sess "$M"; result t2 true)"
expect "no SendMessage call at all"              none    '{"type":"result","subtype":"success","result":"SENT"}'
expect "output that is not JSON"                 none    "Claude AI usage limit reached"
expect "no output"                               none    ""

[ "$FAILS" -eq 0 ] && echo "all passed" || { echo "$FAILS failed"; exit 1; }
