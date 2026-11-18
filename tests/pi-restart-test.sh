#!/bin/sh
set -eu
tuna=${1:?usage: pi-restart-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-pi-restart-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT
failures=0
fail() {
  echo "$0: FAIL: $1"
  failures=$((failures + 1))
}

home=$dir/home
mkdir -p "$home" "$dir/library" "$dir/work"
cp -R tests/pi/home/. "$home/"
sh boot/copy-library.sh "$(dirname "$tuna")/plugins" "$dir/library"

run() {
  (cd "$dir/work" && printf '%s\n' "$1" | HOME="$home" TUNA_LIBRARY="$dir/library" TRANSCRIPT=restart "$tuna" 2>&1)
}

expect() {
  [ "$2" = "$3" ] || fail "$1: expected $(printf '%s' "$3" | tr '\n' '|'), got $(printf '%s' "$2" | tr '\n' '|')"
}

# A quit ends Pi, as processes ends user processes at a quit.
output=$(run '(define chat (pi:start (getenv "HOME") "kept-session"))
(wait-until (lambda () (eq? (pi:chat-activity chat) (quote idle))))
(in-client (lambda () (pi-chat:show! chat)))
(type! "unsent words")
(sleep-for 0.2)
(pi:chat-session-id chat)')
expect "first run" "$output" '"kept-session"'

# The next start starts Pi again on the chat's session, with pi:command
# as the configuration sets it, and the unsent prompt comes back from
# saved data.
output=$(run '(define chat (car (pi:chats)))
(wait-until (lambda () (eq? (pi:chat-activity chat) (quote idle))))
(list (length (pi:chats)) (pi:chat-session-id chat) (fake-args (fake-of chat)))
(shown chat)')
expect "after a restart" "$output" '(1 "kept-session" ("--from-init" "--mode" "rpc" "--session-id" "kept-session"))
"unsent words\n"'

echo "$0: $failures failures"
[ "$failures" -eq 0 ]
