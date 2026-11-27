#!/bin/sh
# The transcript needs web's tests' client, so its configuration is made
# here.
set -eu
tuna=${1:?usage: layout-scroll-float-web-test.sh TUNA}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-layout-scroll-float-web-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT

home=$dir/layout-scroll-float-web/home/.config/tuna
mkdir -p "$home/lib"
cp tests/web/home/.config/tuna/lib/http.sls "$home/lib/"
cat > "$home/init.ss" <<'END'
(import (tuna) (http))
(use-plugin web (config (options:set! web:port (http:free-port))))
(use-plugin layout-scroll)
(use-plugin layout-float)
(import (console))
(http:use-port! (lambda () (web:port)))
(define (served? path file)
  (let ([r (http:get path)])
    (and (= (http:status r) 200)
         (equal? (http:header r "content-type") "text/css; charset=utf-8")
         (string=? (http:body r)
                   (call-with-input-file (string-append (getenv "TUNA_LIBRARY") "/" file) get-string-all)))))
(define (linked name)
  (let ([path (find (lambda (f) (string=? (path-last f) (string-append name "?v=1"))) (http:head-files))])
    (substring path 0 (- (string-length path) 4))))
END

cat > "$dir/layout-scroll-float-web/pages.transcript" <<'END'
Tuna is at http://127.0.0.1:PORT/
> (http:wait-for-server)
; Every page links the strips' and the floats' rules, served as CSS.
> (served? (linked "layout-scroll.css") "layout-scroll/layout-scroll.css")
#t
> (served? (linked "layout-float.css") "layout-float/layout-float.css")
#t
END

# Under make's limit, so a hang stops here, where the runner shows how far
# the transcript got.
TEST_TIMEOUT=40 sh tests/run-transcript.sh "$tuna" "$dir/layout-scroll-float-web/pages.transcript"
