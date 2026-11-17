#!/bin/sh
# The transcript needs web's tests' client beside display's tests'
# layout, so its configuration is made here.
set -eu
tuna=${1:?usage: display-web-test.sh TUNA}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-display-web-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT

lib=$dir/display-web/home/.config/tuna/lib
mkdir -p "$lib"
cp tests/display/home/.config/tuna/lib/layout.sls tests/web/home/.config/tuna/lib/http.sls "$lib/"
cat > "$dir/display-web/home/.config/tuna/init.ss" <<'END'
(import (tuna) (tuna plugins))
(use-plugin web (config (set-option! web:port 19321)))
(use-plugin display)
(import (haml) (http) (console))
(http:use-port! (lambda () (web:port)))
END

cat > "$dir/display-web/screens.transcript" <<'END'
> (http:wait-for-server)
Tuna is at http://127.0.0.1:19321/
; A page carries its first screen, drawn by the batch that connected
; it, and the stream sends only a screen that differs from it.
> (define p (http:page))
> (http:first-screen p)
"<p>Hello from Tuna</p>"
> (http:connect! p)
> (sleep-for 0)
> (http:next p 0.2)
timeout
> (define greeting "Hello again")
> (define (greet screen client) (haml (:p greeting)))
> (advice-add! layout:screen greet)
> (http:show (http:next p))
(screen 1 0 "<p>Hello again</p>")
> (http:confirm! p 1)
204
; A failing draw shows the condition. Its text starts a line of the
; event, after the newline haml writes following <pre>.
> (define (fail screen client) (car '()))
> (advice-add! layout:screen fail)
! car: () is not a pair
> (let* ([lines (map cdr (cdr (http:next p)))] [opening (car lines)] [n (string-length opening)])
    (list (substring opening (- n 27) n) (substring (cadr lines) 0 40)))
("<pre class=\"display-error\">" "Exception in car: () is not a pair</pre>")
> (http:confirm! p 2)
204
> (advice-remove! layout:screen fail)
> (http:show (http:next p))
(screen 3 0 "<p>Hello again</p>")
END

sh tests/run-transcript.sh "$tuna" "$dir/display-web/screens.transcript"
