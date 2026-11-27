(import (tuna) (test) (test-runner) (web) (haml) (tables) (timers) (web-test http) (web-test tasks))

(web-test/http:use-url! (lambda () (web:url)))
(test-runner:wait-until (lambda () (web:url)))

(define (home-file path) (string-append (getenv "HOME") "/.config/tuna/" path))

(define (write-file! path text)
  (call-with-output-file (home-file path) (lambda (p) (put-string p text)) 'replace))

;; The modules stand for the user's own, in lib/, since a test rewrites
;; a file beside one.
(mkdir (home-file "lib/fonts"))
(mkdir (home-file "lib/themes"))
(write-file! "lib/styler.sls" "#!tuna\n(import (web) (tables))\n\n(tables:set! web:stylesheets 'styler \"styler.css\")\n")
(write-file! "lib/styler.css" "main { color: black; }\n")
(write-file! "lib/fonts/mono.woff2" "wOF2")
(write-file! "lib/dark.sls" "#!tuna\n(import (web) (tables))\n\n(tables:set! web:stylesheets 'styler \"themes/dark.css\")\n")
(write-file! "lib/themes/dark.css" "main { color: white; }\n")
(write-file! "extra.css" "p { margin: 0; }\n")
(write-file! "clipboard.js" "export const loaded = true;\n")
(write-file! "placer.js" "window.placed = true;\n")

(define (file path)
  (let ([r (web-test/http:get path)])
    (list (web-test/http:status r) (web-test/http:header r "content-type") (web-test/http:body r))))


(define (head-patch event)
  (and (eq? 'patch (car event))
       (list (cadr event) (caddr event)
             (map (lambda (link)
                    (list (web-test/http:element-attribute link "id") (web-test/http:element-attribute link "href")))
                  (web-test/http:elements-named (cadddr event) 'link)))))

(load-module! '(styler))
(web-test/tasks:settle)

(define p (web-test/http:page))
(web-test/http:connect! p)

(define (next) (web-test/http:next p))

(define slot
  (let ([path (car (web-test/http:head-files))])
    (string->number (substring path 7 (- (string-length path) (string-length "/styler.css?v=1"))))))

(define (at path) (format "/files/~a/~a" slot path))

(define (link-id) (format "tuna-stylesheet-~a" slot))

(test "a module's entry names a file beside the module, which every page links"
  (check-equal? (list (string-append (at "styler.css") "?v=1")) (web-test/http:head-files))
  (check-equal? '(200 "text/css; charset=utf-8" "main { color: black; }\n") (file (at "styler.css"))))

(test "files beside it are served under the same prefix, and nothing outside its folder is"
  (check-equal? '(200 "font/woff2" "wOF2") (file (at "fonts/mono.woff2")))
  (check-equal? '(404 404 404 404 404)
    (map (lambda (path) (web-test/http:status (web-test/http:get path)))
         (list (at "%2e%2e/init.ss") (at "../../init.ss") (at "") (format "/files/~a/styler.css" (+ slot 1)) "/files/x/styler.css"))))

(test "a theme replaces a plugin's stylesheet by setting the same name, and connected pages get it without reloading"
  (load-module! '(dark))
  (check-equal? (list #f #f (list (list (link-id) (string-append (at "dark.css") "?v=1")))) (head-patch (next)))
  (check-equal? '(200 "text/css; charset=utf-8" "main { color: white; }\n") (file (at "dark.css"))))

(test "taking the theme's change back brings the plugin's file back"
  (unload-owner! (module-owner '(dark)))
  (check-equal? (list #f #f (list (list (link-id) (string-append (at "styler.css") "?v=1")))) (head-patch (next))))

(test "a test file's entries are relative to the configuration folder, and a name set later comes later on the page"
  (tables:set! web:stylesheets 'extra "extra.css")
  (let* ([patch (head-patch (next))] [link (car (caddr patch))])
    (check-equal? '("head" "append") (list-head patch 2))
    (check-equal? (list (string-append (at "styler.css") "?v=1") (cadr link)) (web-test/http:head-files))
    (check-equal? '(200 "text/css; charset=utf-8" "p { margin: 0; }\n")
                  (file (substring (cadr link) 0 (- (string-length (cadr link)) 4))))
    (tables:remove! web:stylesheets 'extra)
    (check-equal? (list (string-append "#" (car link)) "remove" '()) (head-patch (next)))))

;; A file is checked for a change at most once a second, so the test
;; waits that long after the last check.
(test "a file changed on disk is read again when a screen is given, and reaches the page before the screen"
  (write-file! "lib/styler.css" "main { color: blue; }\n")
  (timers:sleep 1.1)
  (web:send-screen! (car (web:clients)) (haml (:p "after")) "Tuna")
  (let ([events (web-test/http:take p 2)])
    (check-equal? (list #f #f (list (list (link-id) (string-append (at "styler.css") "?v=2")))) (head-patch (car events)))
    (check-equal? '(screen 1 0 ((p "after"))) (cadr events)))
  (check-equal? '(200 "text/css; charset=utf-8" "main { color: blue; }\n") (file (at "styler.css"))))

(test "an absolute path names the file itself"
  (tables:set! web:stylesheets 'absolute (home-file "extra.css"))
  (let ([link (car (caddr (head-patch (next))))])
    (check-equal? '(200 "text/css; charset=utf-8" "p { margin: 0; }\n") (file (substring (cadr link) 0 (- (string-length (cadr link)) 4)))))
  (tables:remove! web:stylesheets 'absolute)
  (check-equal? "remove" (cadr (head-patch (next)))))

(test "a file that cannot be read is left off the page, with a warning"
  (let ([reported (web-test/tasks:reports-during
                    (lambda ()
                      (tables:set! web:stylesheets 'missing "missing.css")
                      (web-test/tasks:settle)
                      (tables:set! web:stylesheets 'number 42)))])
    (check-equal? (list (list 'web:stylesheets "cannot read the file" (list (home-file "missing.css")))
                        '(web:stylesheets "cannot read the file" (42)))
                  (map (lambda (c) (list (condition-who c) (condition-message c) (condition-irritants c))) reported))
    (check (for-all warning? reported)))
  (check-equal? (list (string-append (at "styler.css") "?v=2")) (web-test/http:head-files))
  (check-equal? 'timeout (web-test/http:next p 0.2)))

(define (head-sources)
  (map (lambda (script) (web-test/http:element-attribute script "src"))
       (web-test/http:elements-named (car (web-test/http:elements-named (web-test/http:page-markup (web-test/http:page)) 'head)) 'script)))

(test "a script's entry makes connected pages reload, since a browser cannot unload a module it has run, and pages load it after Datastar and tuna"
  (tables:set! web:scripts 'clipboard "clipboard.js")
  (check-equal? '((script "location.reload()") closed) (web-test/http:take p 2))
  (let ([script (cadr (web-test/http:head-files))])
    (check-equal? '(200 "text/javascript; charset=utf-8" "export const loaded = true;\n")
                  (file (substring script 0 (- (string-length script) 4))))
    (check-equal? (list "/web/datastar.js" "/web/tuna.js" script) (filter values (head-sources)))))

;; A file is checked for a change at most once a second.
(test "a script file changed on disk makes connected pages reload too, disconnected at once, so the screen that found the change is not sent"
  (let ([q (web-test/http:page)])
    (web-test/http:connect! q)
    (let ([client (car (web:clients))])
      (write-file! "clipboard.js" "export const loaded = 2;\n")
      (timers:sleep 1.1)
      (web:send-screen! client (haml (:p "changed")) "Tuna")
      (check-equal? '() (web:clients)))
    (check-equal? '((script "location.reload()") closed) (web-test/http:take q 2))))

(test "an early script is a classic script that every page runs at the end of its head, and a change reloads pages too"
  (let ([q (web-test/http:page)])
    (web-test/http:connect! q)
    (tables:set! web:early-scripts 'placer "placer.js")
    (check-equal? '((script "location.reload()") closed) (web-test/http:take q 2)))
  (let* ([head (car (web-test/http:elements-named (web-test/http:page-markup (web-test/http:page)) 'head))]
         [last (car (last-pair head))]
         [src (web-test/http:element-attribute last "src")])
    (check-equal? '(script #f) (list (car last) (web-test/http:element-attribute last "type")))
    (check-equal? '(200 "text/javascript; charset=utf-8" "window.placed = true;\n")
                  (file (substring src 0 (- (string-length src) 4))))))
