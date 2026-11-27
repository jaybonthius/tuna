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
(import (tuna) (http))
(use-plugin web (config (options:set! web:port (http:free-port))))
(use-plugin design-tokens)
(use-plugin faces)
(import (console))
(http:use-port! (lambda () (web:port)))
(define (font-served? file)
  (let ([r (http:get (string-append "/files/1/fonts/" file))])
    (and (= (http:status r) 200)
         (equal? (http:header r "content-type") "font/woff2")
         (equal? (http:response-body r)
                 (call-with-port (open-file-input-port (string-append (getenv "TUNA_LIBRARY") "/design-tokens/fonts/" file))
                   get-bytevector-all)))))
(define (page-has? text)
  (let ([page (http:body (http:get "/"))])
    (let loop ([i 0])
      (and (<= (+ i (string-length text)) (string-length page))
           (or (string=? (substring page i (+ i (string-length text))) text) (loop (+ i 1)))))))
(define (served? path file)
  (let ([r (http:get path)])
    (and (= (http:status r) 200)
         (equal? (http:header r "content-type") "text/css; charset=utf-8")
         (string=? (http:body r)
                   (call-with-input-file (string-append (getenv "TUNA_LIBRARY") "/" file) get-string-all)))))
END
cat > "$home/lib/dusk.sls" <<'END'
#!tuna
(import (web) (tables))

(tables:set! web:stylesheets 'theme "dusk/dusk.css")
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
Tuna is at http://127.0.0.1:PORT/
> (http:wait-for-server)
; Every page links the token file and the faces' rules, served as CSS.
> (http:head-files)
("/files/1/design-tokens.css?v=1" "/files/2/faces.css?v=1")
> (list (served? "/files/1/design-tokens.css" "design-tokens/design-tokens.css") (served? "/files/2/faces.css" "faces/faces.css"))
(#t #t)
; The fonts the token file names are served from its folder, whole.
> (map font-served? '("FiraSans-Regular.woff2" "FiraSans-SemiBold.woff2" "FiraSans-Bold.woff2" "FiraCode-VF.woff2"))
(#t #t #t #t)
; The page asks for light and dark before any stylesheet loads, so the
; browser paints the right background first.
> (page-has? "<meta name=\"color-scheme\" content=\"light dark\">")
#t
; A theme is a plugin that registers its file as theme; the user's
; tweaks are a file of the configuration's, beating any theme.
> (import (dusk))
> (tables:set! web:stylesheets 'user "user.css")
> (http:head-files)
("/files/1/design-tokens.css?v=1" "/files/2/faces.css?v=1" "/files/3/dusk.css?v=1" "/files/4/user.css?v=1")
; Turning the theme off takes its file back.
> (unload-owner! (module-owner '(dusk)))
> (http:head-files)
("/files/1/design-tokens.css?v=1" "/files/2/faces.css?v=1" "/files/4/user.css?v=1")
END

# Under make's limit, so a hang stops here, where the runner shows how far
# the transcript got.
TEST_TIMEOUT=40 sh tests/run-transcript.sh "$tuna" "$dir/design-tokens-web/pages.transcript"
