#!/bin/sh
# Layout draws through the web plugin itself, so this configuration has
# no stand-in web, unlike the layout-draw folder's.
set -eu
tuna=${1:?usage: layout-draw-web-test.sh TUNA}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-layout-draw-web-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT

lib=$dir/layout-draw-web/home/.config/tuna/lib
mkdir -p "$lib"
cp tests/web/home/.config/tuna/lib/http.sls "$lib/"
cat > "$dir/layout-draw-web/home/.config/tuna/init.ss" <<'END'
(import (tuna) (tuna plugins) (http))
(use-plugin web (config (set-option! web:port (http:free-port))))
(use-plugin layout)
(import (haml) (console))
(http:use-port! (lambda () (web:port)))
(define (hello screen client) (haml (:p "Hello from Tuna")))
(advice-add! layout:screen hello)
END

cat > "$dir/layout-draw-web/screens.transcript" <<'END'
Tuna is at http://127.0.0.1:PORT/
> (http:wait-for-server)
> (define (title-of html)
    (let* ([start (http:search html "<title" 0)] [end (http:search html "</title>" start)])
      (substring html start (+ end 8))))
; A page carries its first screen and title, drawn by the batch that
; connected it, and the stream sends only a screen that differs from it.
> (define p (http:page))
> (list (http:first-screen p) (title-of (http:page-html p)))
("<p>Hello from Tuna</p>" "<title id=\"tuna-title\">*scratch* - Tuna</title>")
> (http:connect! p)
; Keys gives a page its settings when it connects.
> (car (http:show (http:next p)))
script
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
; A new buffer in the selected view retitles the page.
> (layout:switch-to-buffer (buffers:make "notes" ""))
> (http:show (http:next p))
(datastar-patch-elements ("elements" "<title id=\"tuna-title\">notes - Tuna</title>"))
; A failing draw shows the condition, and the page keeps its title. Its
; text starts a line of the event, after the newline haml writes following
; <pre>.
> (define (fail screen client) (car '()))
> (advice-add! layout:screen fail)
! car: () is not a pair
> (let* ([lines (map cdr (cdr (http:next p)))] [opening (car lines)] [n (string-length opening)])
    (list (substring opening (- n 26) n) (substring (cadr lines) 0 40)))
("<pre class=\"layout-error\">" "Exception in car: () is not a pair</pre>")
> (http:confirm! p 2)
204
> (advice-remove! layout:screen fail)
> (http:show (http:next p))
(screen 3 0 "<p>Hello again</p>")
END

# Under make's limit, so a hang stops here, where the runner shows how far
# the transcript got.
TEST_TIMEOUT=40 sh tests/run-transcript.sh "$tuna" "$dir/layout-draw-web/screens.transcript"
