#!/bin/sh
# The transcript needs web's tests' client, so its configuration is made
# here.
set -eu
tuna=${1:?usage: design-tokens-web-test.sh TUNA}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-design-tokens-web-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT

home=$dir/design-tokens-web/home/.config/tuna
mkdir -p "$home/lib/dusk"
cp tests/web/home/.config/tuna/lib/http.sls "$home/lib/"
cat > "$home/init.ss" <<'END'
(import (tuna) (tuna plugins))
(use-plugin web (config (set-option! web:port 19322)))
(use-plugin design-tokens)
(use-plugin faces)
(import (http) (console))
(http:use-port! (lambda () (web:port)))
(define (served? path file)
  (let ([r (http:get path)])
    (and (= (http:status r) 200)
         (equal? (http:header r "content-type") "text/css; charset=utf-8")
         (string=? (http:body r)
                   (call-with-input-file (string-append (getenv "TUNA_LIBRARY") "/" file) get-string-all)))))
END
cat > "$home/lib/dusk.sls" <<'END'
#!tuna
(import (web))

(table-set! web:stylesheets 'theme "dusk/dusk.css")
END
cat > "$home/lib/dusk/dusk.css" <<'END'
@layer defaults, themes, preferences;

@layer themes {
  :root {
    color-scheme: dark;
    --tuna-cursor: var(--tuna-amber-9);
    --tuna-region: var(--tuna-orange-4);
    --faces-keyword-color: var(--tuna-orange-11);
    --faces-comment-color: var(--tuna-gray-10);
  }

  [data-face="comment"], :where([data-face^="comment."]) {
    font-style: italic;
  }
}
END
printf ':root { --tuna-region: #264f78; }\n' > "$home/user.css"

cat > "$dir/design-tokens-web/pages.transcript" <<'END'
> (http:wait-for-server)
Tuna is at http://127.0.0.1:19322/
; Every page links the token file and the faces' rules, served as CSS.
> (http:head-files)
("/files/1/design-tokens.css?v=1" "/files/2/faces.css?v=1")
> (list (served? "/files/1/design-tokens.css" "design-tokens/design-tokens.css") (served? "/files/2/faces.css" "faces/faces.css"))
(#t #t)
; A theme is a plugin that registers its file as theme; the user's
; tweaks are a file of the configuration's, beating any theme.
> (import (dusk))
> (table-set! web:stylesheets 'user "user.css")
> (http:head-files)
("/files/1/design-tokens.css?v=1" "/files/2/faces.css?v=1" "/files/3/dusk.css?v=1" "/files/4/user.css?v=1")
; Turning the theme off takes its file back.
> (unload-module! '(dusk))
> (http:head-files)
("/files/1/design-tokens.css?v=1" "/files/2/faces.css?v=1" "/files/4/user.css?v=1")
END

sh tests/run-transcript.sh "$tuna" "$dir/design-tokens-web/pages.transcript"
