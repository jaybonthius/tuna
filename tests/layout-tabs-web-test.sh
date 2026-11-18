#!/bin/sh
# The transcript needs web's tests' client, so its configuration is made
# here.
set -eu
tuna=${1:?usage: layout-tabs-web-test.sh TUNA}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-layout-tabs-web-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT

home=$dir/layout-tabs-web/home/.config/tuna
mkdir -p "$home/lib"
cp tests/web/home/.config/tuna/lib/http.sls "$home/lib/"
cat > "$home/init.ss" <<'END'
(import (tuna) (tuna plugins) (http))
(use-plugin web (config (set-option! web:port (http:free-port))))
(use-plugin layout-tabs)
(import (console))
(http:use-port! (lambda () (web:port)))
(define (served? path file)
  (let ([r (http:get path)])
    (and (= (http:status r) 200)
         (equal? (http:header r "content-type") "text/css; charset=utf-8")
         (string=? (http:body r)
                   (call-with-input-file (string-append (getenv "TUNA_LIBRARY") "/" file) get-string-all)))))
END

cat > "$dir/layout-tabs-web/pages.transcript" <<'END'
> (http:wait-for-server)
Tuna is at http://127.0.0.1:PORT/
; Every page links the tabs' rules, served as CSS.
> (define path (find (lambda (f) (string=? (path-last f) "layout-tabs.css?v=1")) (http:head-files)))
> (served? (substring path 0 (- (string-length path) 4)) "layout-tabs/layout-tabs.css")
#t
END

sh tests/run-transcript.sh "$tuna" "$dir/layout-tabs-web/pages.transcript"
