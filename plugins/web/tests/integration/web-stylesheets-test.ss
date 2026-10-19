;;; Stylesheet delivery by the web transport over real loopback HTTP: the
;;; page's head links each registered stylesheet, its URL serves the text,
;;; stale hashes get 404, files beside it are served with validators, and
;;; every screen stream gets the head first and again whenever it changes.
;;; A plugin in this test registers one stylesheet from a temporary
;;; directory, under an owner name with a slash in it.
(import :std/crypto/digest
        :std/encoding/hex
        :std/io
        :std/misc/ports
        :std/test
        :tuna/kernel
        :tuna/plugins/stylesheets/contract
        :tuna/plugins/web/plugin
        "../support/web-client"
        (only-in "../../../../tuna/tests/support/string-input" test-input))
(export web-stylesheets-test)

(def style-directory
  (path-expand (string-append "tuna-web-stylesheets-test-" (number->string (random-integer 1000000000)))
               (getenv "TMPDIR" "/tmp")))
(def style-file (path-expand "style.css" style-directory))
(def first-text "body { color: var(--x, black); }\n")

(defplugin (web-test/styled ctx)
  "Adds one stylesheet from the test's temporary directory."
  (add-stylesheet 'rules style-file))

(def (write-style! (text : :string))
  (write-file-string style-file text))

(def (with-styled-tuna thunk)
  (create-directory* (path-expand "fonts" style-directory))
  (write-style! first-text)
  (write-file-string (path-expand "fonts/x.woff2" style-directory) "wOF2 font bytes")
  (write-file-string (path-expand "other.css" style-directory) "p { margin: 0; }\n")
  (write-file-string (path-expand "secret.ss" style-directory) "(def secret 1)\n")
  (try
   (with-web-tuna [test-input web-transport web-test/styled]
     (lambda ()
       ;; The loop redisplays once before it runs any task, so after this
       ;; the head links the registry's stylesheets.
       (call-on-editor-loop void)
       (thunk)))
   (finally
    (delete-file-or-directory style-directory #t))))

(def link-id "css__web-test_2fstyled__rules")

;; The URL prefix of the test's stylesheet with TEXT, as slot N.
(def (style-prefix (text : :string) (n : :fixnum))
  (string-append "/css/" (number->string n) "/" (hex-encode (sha256 (string->utf8 text))) "/"))

;; The slot number the page links the test's stylesheet under. The web
;; transport's own stylesheets take slots too, in an order this test does
;; not fix.
(def (style-slot)
  (let* ((page (reply-body (http "GET" "/")))
         (marker (string-append "id=\"" link-id "\" rel=\"stylesheet\" href=\"/css/"))
         (start (+ (string-search marker page) (string-length marker))))
    (string->number (substring page start (string-index page #\/ start)))))

(def (style-href (text : :string))
  (string-append (style-prefix text (style-slot)) "style.css"))

;; The <head>…</head> of TEXT.
(def (head-of text)
  (let (start (string-search "<head>" text))
    (substring text start (+ (string-search "</head>" text) 7))))

;; Read STREAM until (DONE? text); fail the test instead of hanging.
(def (read-stream-until stream done?)
  (let (text (read-until stream done?))
    (check (and (done? text) #t) => #t)
    text))

(def web-stylesheets-test
  (test-suite "tuna/plugins/web: stylesheets"
    (test-case "the head links each stylesheet by a stable id, before the scripts"
      (with-styled-tuna
       (lambda ()
         (let* ((page (reply-body (http "GET" "/")))
                (head (head-of page))
                (href (style-href first-text)))
           (check (and (string-search (string-append "<link id=\"" link-id "\" rel=\"stylesheet\" href=\""
                                                     href "\">")
                                      head)
                       #t)
                  => #t)
           (check (string-search "/static/tuna.css" head) => #f)
           (check (< (string-search href head) (string-search "<script" head)) => #t)))))

    (test-case "a stylesheet URL serves its text as immutable CSS; other hashes get 404"
      (with-styled-tuna
       (lambda ()
         (let* ((text first-text)
                (reply (http "GET" (style-href text))))
           (check (reply-status reply) => 200)
           (check (reply-body reply) => text)
           (check (reply-header reply "Content-Type") => "text/css; charset=utf-8")
           (check (reply-header reply "Cache-Control") => "public, max-age=31536000, immutable"))
         (check (reply-status (http "GET" (style-href "stale"))) => 404)
         (check (reply-status (http "GET" (string-append (style-prefix first-text (+ (style-slot) 100)) "style.css"))) => 404)
         (check (reply-status (http "GET" "/css/")) => 404))))

    (test-case "files beside a stylesheet are served with an ETag; .. and other types are refused"
      (with-styled-tuna
       (lambda ()
         (let* ((prefix (style-prefix first-text (style-slot)))
                (font (http "GET" (string-append prefix "fonts/x.woff2")))
                (etag (reply-header font "ETag")))
           (check (reply-status font) => 200)
           (check (reply-body font) => "wOF2 font bytes")
           (check (reply-header font "Content-Type") => "font/woff2")
           (check (reply-header font "Cache-Control") => "no-cache")
           (check (string? etag) => #t)
           (check (reply-status (http "GET" (string-append prefix "fonts/x.woff2")
                                      headers: [(cons "If-None-Match" etag)]))
                  => 304)
           (check (reply-header (http "GET" (string-append prefix "other.css")) "Content-Type")
                  => "text/css; charset=utf-8")
           (for-each
            (lambda (rest)
              (check [rest (reply-status (http "GET" (string-append prefix rest)))] => [rest 404]))
            ["../style.css" "fonts/../other.css" "./other.css" "%2e%2e/style.css" "/etc/hosts"
             "fonts//x.woff2" "fonts" "secret.ss" "fonts/missing.woff2"])))))

    (test-case "a stream that opens receives the head before the screen"
      (with-styled-tuna
       (lambda ()
         (let* ((page-head (head-of (reply-body (http "GET" "/"))))
                (stream (open-screen-stream))
                (text (read-stream-until stream (lambda (text) (string-search "id=\"screen\"" text)))))
           (check (and (string-search page-head text) #t) => #t)
           (check (< (string-search "<head>" text) (string-search "id=\"screen\"" text)) => #t)
           (Socket-close stream)))))

    (test-case "a changed file, after reread, gets a new URL sent to the stream as a head morph"
      (with-styled-tuna
       (lambda ()
         (let* ((old-href (style-href first-text))
                (new-text "body { color: var(--x, navy); }\n")
                (new-href (style-href new-text))
                (stream (open-screen-stream)))
           (read-stream-until stream (lambda (text) (string-search "id=\"screen\"" text)))
           (write-style! new-text)
           (check (call-on-editor-loop reread-stylesheets!) => 1)
           ;; The new head, then a screen after it.
           (let (text (read-stream-until
                       stream
                       (lambda (text)
                         (let (at (string-search new-href text))
                           (and at (string-search "id=\"screen\"" (substring text at (string-length text))))))))
             (check (and (string-search (string-append "<link id=\"" link-id "\" rel=\"stylesheet\" href=\""
                                                       new-href "\">")
                                        text)
                         #t)
                    => #t))
           (Socket-close stream)
           (check (reply-status (http "GET" old-href)) => 404)
           (check (reply-body (http "GET" new-href)) => new-text)
           (check (and (string-search new-href (reply-body (http "GET" "/"))) #t) => #t)))))))
