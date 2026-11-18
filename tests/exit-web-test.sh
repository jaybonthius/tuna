#!/bin/sh
# C-x C-c from a page runs inside web's handling of the key, under every
# bundled plugin a full configuration loads, so the exit happens with
# their code on the stack; the exit transcripts run it from the
# console with few plugins. The page is a second Tuna, since the one
# under test must be free to end.
set -eu
tuna=${1:?usage: exit-web-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-exit-web-test.XXXXXX")
pid=
cleanup() {
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
    wait "$pid" || true
  fi
  rm -rf "$dir"
}
trap cleanup EXIT

server=$dir/server
client=$dir/client
mkdir -p "$server/.config/tuna" "$client/.config/tuna/lib" "$dir/library" "$dir/work"
sh boot/copy-library.sh "$(dirname "$tuna")/plugins" "$dir/library"
cp tests/web/home/.config/tuna/lib/http.sls "$client/.config/tuna/lib/"
cat > "$server/.config/tuna/init.ss" <<'END'
(import (tuna) (tuna plugins))
(use-plugin jobs)
(use-plugin document)
(use-plugin buffers)
(use-plugin commands)
(use-plugin web (config (set-option! web:port 19351)))
(use-plugin design-tokens)
(use-plugin modus)
(use-plugin faces)
(use-plugin views)
(use-plugin kill-ring)
(use-plugin keys)
(use-plugin ui)
(use-plugin layout)
(use-plugin repeat)
(use-plugin layout-split)
(use-plugin layout-tabs)
(use-plugin layout-scroll)
(use-plugin layout-float)
(use-plugin modes)
(use-plugin auto-mode)
(use-plugin files)
(use-plugin undo)
(use-plugin undo-log)
(use-plugin editing)
(use-plugin clipboard)
(use-plugin echo-area)
(use-plugin status-line)
(use-plugin minibuffer)
(use-plugin completion)
(use-plugin completion-list)
(use-plugin completion-popup)
(use-plugin completion-annotations)
(use-plugin file-picker)
(use-plugin buffer-picker)
(use-plugin command-picker)
(use-plugin line-picker)
(use-plugin grep)
(use-plugin display)
(use-plugin command-line)
END
cat > "$client/.config/tuna/init.ss" <<'END'
(import (tuna) (tuna plugins) (http) (console))
(http:use-port! (lambda () 19351))
END
printf 'one\n' > "$dir/work/notes.txt"

(cd "$dir/work" && HOME="$server" TUNA_LIBRARY="$dir/library" exec "$tuna" notes.txt \
  < /dev/null > "$dir/server.out" 2>&1) &
pid=$!

# The page gives up on the server after about five seconds, and a fresh
# Tuna compiles every plugin before it listens.
tries=0
until grep -q '^Tuna is at ' "$dir/server.out" 2>/dev/null; do
  if ! kill -0 "$pid" 2>/dev/null || [ "$tries" -ge 450 ]; then
    echo "$0: FAIL: Tuna did not start; it printed:"
    cat "$dir/server.out"
    exit 1
  fi
  sleep 0.1
  tries=$((tries + 1))
done

output=$(cd "$dir/work" && printf '%s\n' \
  '(http:wait-for-server)' \
  '(define p (http:page))' \
  '(http:connect! p)' \
  '(http:send! p (quote (("type" . "key") ("key" . "x") ("code" . "KeyX") ("modifiers" . #("control")))))' \
  '(http:send! p (quote (("type" . "key") ("key" . "c") ("code" . "KeyC") ("modifiers" . #("control")))))' \
  | HOME="$client" TUNA_LIBRARY="$dir/library" "$tuna" 2>&1)
expected='204
204'
if [ "$output" != "$expected" ]; then
  echo "$0: FAIL: the page: expected $(printf '%s' "$expected" | tr '\n' '|'), got $(printf '%s' "$output" | tr '\n' '|')"
  exit 1
fi

tries=0
while kill -0 "$pid" 2>/dev/null && [ "$tries" -lt 100 ]; do
  sleep 0.1
  tries=$((tries + 1))
done
if kill -0 "$pid" 2>/dev/null; then
  echo "$0: FAIL: Tuna was still running 10 seconds after C-x C-c; it printed:"
  cat "$dir/server.out"
  exit 1
fi
status=0
wait "$pid" || status=$?
pid=
if [ "$status" -ne 0 ] || [ "$(cat "$dir/server.out")" != 'Tuna is at http://127.0.0.1:19351/' ]; then
  echo "$0: FAIL: expected status 0 and only the address printed, got status $status and:"
  cat "$dir/server.out"
  exit 1
fi
echo "$0: ok"
