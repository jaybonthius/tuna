;;; The web transport over real loopback HTTP on an ephemeral port: the
;;; plain URL, Host and Origin checks, event requests (keydowns, pointer
;;; and scroll items, validated strictly, and the screen revision pointer
;;; and scroll items name), and the screen stream's re-sends. A stand-in provides the input the
;;; editor loop needs; another records the items it resolves.
(import :std/io
        :std/test
        :tuna/kernel
        :tuna/plugins/keys/contract
        :tuna/plugins/web/plugin
        "../support/web-client"
        (only-in "../../../../tuna/tests/support/string-input" test-input test-messages))
(export web-test)

(def web-plugins
  [test-input web-transport])

(def (with-tuna thunk)
  (with-web-tuna web-plugins thunk))

;; An input provider that records every item it resolves, newest first.
(defstruct input-recorder (items) final: #t)

(defmethod {resolve! input-recorder}
  (lambda (self item)
    (set! (input-recorder-items self) (cons item (input-recorder-items self)))
    #f))

(defmethod {arrival input-recorder}
  (lambda (self item) 'queue))

(def recorded (make-input-recorder []))

(defplugin (recording-input ctx)
  "Records the input items it resolves."
  provides: [input-service]
  (context-provide! ctx input-service recorded))

;; The items resolved so far, oldest first, once there are COUNT of them.
(def (recorded-items count)
  (let lp ((tries 300))
    (let (items (call-on-editor-loop (lambda () (input-recorder-items recorded))))
      (if (or (>= (length items) count) (zero? tries))
        (reverse items)
        (begin (thread-sleep! 0.01) (lp (- tries 1)))))))

(def (post-json body)
  (reply-status (http "POST" "/commands"
                      headers: [(cons "Datastar-Request" "true")
                                (cons "Content-Type" "application/json")]
                      body: body)))

;; A scroll item as JSON: view 12's text node 4 on screen 0, line 30 at
;; the top, with the fields in CHANGES, each (name . raw-json), or (name .
;; #f) to leave the field out.
(def (scroll-json . changes)
  (let* ((fields '(("version" . "1") ("type" . "\"scroll\"") ("sequence" . "1") ("revision" . "0")
                   ("view" . "12") ("node" . "4") ("top" . "30") ("offset" . "5.5") ("last" . "61")
                   ("at" . "700.25") ("drawnStart" . "0") ("drawnEnd" . "9600")
                   ("drawnFirst" . "1") ("drawnLast" . "400") ("height" . "744") ("request" . "0")))
         (merged (filter cdr (map (lambda (field) (or (assoc (car field) changes) field)) fields))))
    (string-append
     "{"
     (string-join (map (lambda (field) (string-append "\"" (car field) "\":" (cdr field))) merged) ",")
     "}")))

;; The data-revision of each screen event in TEXT, oldest first.
(def (screen-revisions text)
  (let lp ((rest text) (out []))
    (let (at (string-search "data-revision=\"" rest))
      (if at
        (let* ((from (+ at 15))
               (to (string-index rest #\" from)))
          (lp (substring rest to (string-length rest))
              (cons (string->number (substring rest from to)) out)))
        (reverse out)))))

(def web-test
  (test-suite "tuna/plugins/web"
    (test-case "the plain URL opens without a token or cookie"
      (with-tuna
       (lambda ()
         (check (web-transport-url) => (string-append "http://" (host) "/"))
         (let (page (http "GET" "/"))
           (check (reply-status page) => 200)
           (check (reply-header page "Set-Cookie") => #f)
           (check (and (string-search "id=\"screen\"" (reply-body page)) #t) => #t)
           (check (and (string-search "No renderer is active." (reply-body page)) #t) => #t))
         (check (reply-status (http "GET" "/static/tuna-input.js")) => 200)
         (check (reply-status (http "GET" "/elsewhere")) => 404))))

    (test-case "a foreign Host or Origin is refused on every route"
      (with-tuna
       (lambda ()
         (for-each
          (lambda (path)
            (check (reply-status (http "POST" path host: "evil.example")) => 403)
            (check (reply-status (http "POST" path headers: [(cons "Origin" "http://evil.example")])) => 403))
          ["/" "/screen" "/commands" "/static/tuna-input.js"])
         (check (reply-status (http "GET" "/" host: (string-append "localhost:" (number->string port))))
                => 403)
         (check (reply-status (http "GET" "/" headers: [(cons "Origin" "http://evil.example")])) => 403)
         (check (reply-status (http "POST" "/commands"
                                    headers: [(cons "Origin" "http://evil.example")
                                              (cons "Datastar-Request" "true")
                                              (cons "Content-Type" "application/json")]
                                    body: (keydown-json "a" #f 1)))
                => 403)
         (check (reply-status (http "GET" "/" headers: [(cons "Origin" (string-append "http://" (host)))]))
                => 200))))

    (test-case "all command requests get 204, including malformed requests"
      (with-tuna
       (lambda ()
         (check (reply-status (post-key "a")) => 204)
         (check (post-json "not JSON") => 204)
         (check (post-json "[]") => 204)
         (check (reply-status (http "GET" "/commands")) => 204)
         (check (reply-status (http "POST" "/commands"
                                    headers: [(cons "Datastar-Request" "true")
                                              (cons "Content-Type" "application/json")]
                                    body: "{\"version\":1,\"type\":\"keydown\"}"))
                => 204)
         (check (reply-status (http "POST" "/commands"
                                    headers: [(cons "Content-Type" "application/json")]
                                    body: (keydown-json "a" #f 2)))
                => 204)
         (check (reply-status (http "POST" "/commands"
                                    headers: [(cons "Datastar-Request" "true")
                                              (cons "Content-Type" "text/plain")]
                                    body: (keydown-json "a" #f 3)))
                => 204))))

    (test-case "out-of-order keys and clicks are submitted in order; duplicates are ignored"
      (set! (input-recorder-items recorded) [])
      (with-web-tuna [test-messages recording-input web-transport]
       (lambda ()
         (check (post-json (keydown-json "c" #f 3)) => 204)
         (check (post-json (keydown-json "duplicate" #f 3)) => 204)
         (check (post-json (keydown-json "a" #f 1)) => 204)
         (check (post-json (pointer-json (cons "sequence" "2"))) => 204)
         (check (post-json (keydown-json "duplicate" #f 1)) => 204)
         (let (items (recorded-items 3))
           (check (length items) => 3)
           (check (key-event-key (car items)) => "a")
           (check (pointer-event? (cadr items)) => #t)
           (check (key-event-key (caddr items)) => "c")))))

    (test-case "a page reload restarts numbering and drops the old page's early items"
      (set! (input-recorder-items recorded) [])
      (with-web-tuna [test-messages recording-input web-transport]
       (lambda ()
         (check (post-json (keydown-json "a" #f 1)) => 204)
         (check (post-json (keydown-json "old" #f 3)) => 204)
         (check (reply-status (http "GET" "/")) => 200)
         (check (post-json (keydown-json "b" #f 1)) => 204)
         (check (post-json (keydown-json "c" #f 2)) => 204)
         (check (map key-event-key (recorded-items 3)) => ["a" "b" "c"]))))

    (test-case "a screen stream that reconnects without a reload keeps the numbering"
      (set! (input-recorder-items recorded) [])
      (with-web-tuna [test-messages recording-input web-transport]
       (lambda ()
         (let (first (open-screen-stream))
           (check (post-json (keydown-json "a" #f 1)) => 204)
           (check (post-json (keydown-json "b" #f 2)) => 204)
           (Socket-close first))
         (let (second (open-screen-stream))
           (check (and (string-search "datastar-patch-elements"
                                     (read-until second (lambda (text)
                                                          (string-search "datastar-patch-elements" text)))) #t)
                  => #t)
           (check (post-json (keydown-json "c" #f 3)) => 204)
           (check (map key-event-key (recorded-items 3)) => ["a" "b" "c"])
           (Socket-close second)))))

    (test-case "after a server restart, the open page's next number is taken as the start"
      (set! (input-recorder-items recorded) [])
      (with-web-tuna [test-messages recording-input web-transport]
       (lambda ()
         (check (post-json (keydown-json "x" #f 57)) => 204)
         (check (post-json (keydown-json "y" #f 58)) => 204)
         (check (map key-event-key (recorded-items 2)) => ["x" "y"]))
       load-page?: #f))

    (test-case "a missing item that 64 later ones wait for is skipped; input carries on"
      (set! (input-recorder-items recorded) [])
      (with-web-tuna [test-messages recording-input web-transport]
       (lambda ()
         (let lp ((sequence 2))
           (when (<= sequence 66)
             (check (post-json (keydown-json (number->string sequence) #f sequence)) => 204)
             (lp (+ sequence 1))))
         ;; The missing item arriving late is ignored, still with 204.
         (check (post-json (keydown-json "late" #f 1)) => 204)
         (check (post-json (keydown-json "after" #f 67)) => 204)
         (let (keys (map key-event-key (recorded-items 66)))
           (check (car keys) => "2")
           (check (list-ref keys 64) => "66")
           (check (list-ref keys 65) => "after")
           (check (member "late" keys) => #f)))))

    (test-case "key items preserve platform, held Option sides and AltGraph facts"
      (set! (input-recorder-items recorded) [])
      (with-web-tuna [test-messages recording-input web-transport]
       (lambda ()
         (check (post-json (keydown-json "≈" #f 1 (cons "code" "\"KeyX\"")
                                        (cons "altKey" "true") (cons "isMac" "true")
                                        (cons "altLeft" "true") (cons "altRight" "false")
                                        (cons "altGraph" "false"))) => 204)
         (check (post-json (keydown-json "@" #t 2 (cons "altKey" "true")
                                        (cons "altRight" "true") (cons "altGraph" "true"))) => 204)
         (let (items (recorded-items 2))
           (check (length items) => 2)
           (let ((mac (car items)) (graph (cadr items)))
             (check [(key-event-key mac) (key-event-code mac) (key-event-sequence mac)] => ["≈" "KeyX" 1])
             (check [(key-event-mac? mac) (key-event-alt-left? mac)
                     (key-event-alt-right? mac) (key-event-alt-graph? mac)] => [#t #t #f #f])
             (check [(key-event-mac? graph) (key-event-alt-left? graph)
                     (key-event-alt-right? graph) (key-event-alt-graph? graph)] => [#f #f #t #t]))))))

    (test-case "missing or malformed keyboard facts get 204 without being submitted"
      (set! (input-recorder-items recorded) [])
      (with-web-tuna [test-messages recording-input web-transport]
       (lambda ()
         (check (post-json (keydown-json "x" #f 1)) => 204)
         (for-each
          (lambda (field)
            (for-each (lambda (bad)
                        (check [field bad (post-json (keydown-json "x" #f 2 (cons field bad)))]
                               => [field bad 204]))
                      [#f "null" "0" "1" "\"true\"" "[]" "{}"]))
          ["isMac" "altLeft" "altRight" "altGraph"])
         (check (length (recorded-items 1)) => 1))))

    (test-case "each screen carries its revision on its root element"
      (with-tuna
       (lambda ()
         (let (page (reply-body (http "GET" "/")))
           (check (and (string-search "<main data-revision=\"" page) #t) => #t)
           (check (fixnum? (page-revision)) => #t)))))

    (test-case "a pointer item becomes a pointer event: Emacs's button, its part, node and screen"
      (set! (input-recorder-items recorded) [])
      (with-web-tuna [test-messages recording-input web-transport]
       (lambda ()
         (let (revision (page-revision))
           (check (post-json (pointer-json (cons "revision" (number->string revision))
                                           (cons "button" "2") (cons "clicks" "2")
                                           (cons "target" "\"status-line:12\"") (cons "node" "4")
                                           (cons "modifiers" "{\"alt\":false,\"ctrl\":true,\"meta\":false,\"shift\":true}")))
                  => 204)
           (check (post-json (pointer-json (cons "sequence" "2") (cons "node" #f))) => 204)
           (let (items (recorded-items 2))
             (check (length items) => 2)
             (let ((e (car items))
                   (bare (cadr items)))
               (check (pointer-event-button e) => 3)
               (check (pointer-event-clicks e) => 2)
               (check [(pointer-event-alt? e) (pointer-event-ctrl? e)
                       (pointer-event-meta? e) (pointer-event-shift? e)]
                      => [#f #t #f #t])
               (check (pointer-event-names e) => ["C-S-double-mouse-3" "C-S-mouse-3"])
               (let (p (pointer-event-start e))
                 (check [(posn-area p) (posn-part p) (posn-node-id p) (posn-revision p)]
                        => ['status-line 12 4 revision]))
               (check (posn-node-id (pointer-event-start bare)) => #f)
               (check (pointer-event-button bare) => 1)))))))

    (test-case "malformed and forged pointer items get 204 without being submitted"
      (set! (input-recorder-items recorded) [])
      (with-web-tuna [test-messages recording-input web-transport]
       (lambda ()
         (check (post-json (pointer-json)) => 204)
         (for-each
           (lambda (change)
             (check [change (post-json (pointer-json change (cons "sequence" "2")))] => [change 204]))
           '(("version" . "2") ("type" . "\"pointerdown\"") ("kind" . "\"drop\"") ("kind" . #f)
             ("sequence" . "-1") ("sequence" . "0") ("sequence" . "\"1\"")
             ;; A screen the transport never sent.
             ("revision" . "999999") ("revision" . "-1") ("revision" . #f)
             ("button" . "3") ("button" . "-1") ("button" . "0.5")
             ("clicks" . "0") ("clicks" . "256") ("clicks" . "true")
             ("modifiers" . "{\"alt\":false,\"ctrl\":false,\"meta\":false}")
             ("modifiers" . "{\"alt\":0,\"ctrl\":false,\"meta\":false,\"shift\":false}")
             ("modifiers" . "[]")
             ("target" . "\"tab-line\"") ("target" . "\"tab-line:\"") ("target" . "\":30\"")
             ("target" . "\"Tab-line:30\"") ("target" . "\"tab-line:-30\"") ("target" . "\"tab-line:30:31\"")
             ("target" . "\"tab-line:3x\"") ("target" . "\"1tab-line:30\"") ("target" . "30") ("target" . #f)
             ("target" . "\"tab-line:1234567890123456\"")
             ("node" . "\"4\"") ("node" . "-4") ("node" . "4.5")))
         (check (length (recorded-items 1)) => 1))))

    (test-case "a scroll item becomes a scroll event naming its view, text node and screen"
      (set! (input-recorder-items recorded) [])
      (with-web-tuna [test-messages recording-input web-transport]
       (lambda ()
         (let (revision (page-revision))
           (check (post-json (scroll-json (cons "revision" (number->string revision)))) => 204)
           (check (post-json (scroll-json (cons "sequence" "2") (cons "top" "null") (cons "last" "null")
                                          (cons "request" "3"))) => 204)
           (let (items (recorded-items 2))
             (check (length items) => 2)
             (let ((e (car items))
                   (bare (cadr items)))
               (let (p (scroll-event-start e))
                 (check [(posn-area p) (posn-part p) (posn-node-id p) (posn-revision p)]
                        => ['view 12 4 revision]))
               (check [(scroll-event-top-line e) (scroll-event-top-offset e) (scroll-event-last-line e)]
                      => [30 5.5 61])
               (check [(scroll-event-viewport-top e) (scroll-event-drawn-start e) (scroll-event-drawn-end e)]
                      => [700.25 0. 9600.])
               (check [(scroll-event-drawn-first e) (scroll-event-drawn-last e)
                       (scroll-event-viewport-height e) (scroll-event-request e)]
                      => [1 400 744 0])
               (check [(scroll-event-top-line bare) (scroll-event-last-line bare) (scroll-event-request bare)]
                      => [#f #f 3])))))))

    (test-case "malformed and forged scroll items get 204 without being submitted"
      (set! (input-recorder-items recorded) [])
      (with-web-tuna [test-messages recording-input web-transport]
       (lambda ()
         (check (post-json (scroll-json)) => 204)
         (for-each
           (lambda (change)
             (check [change (post-json (scroll-json change (cons "sequence" "2")))] => [change 204]))
           '(("version" . "2") ("type" . "\"scrolled\"")
             ("sequence" . "0") ("sequence" . "\"2\"")
             ;; A screen the transport never sent.
             ("revision" . "999999") ("revision" . "-1")
             ("view" . "-1") ("view" . "\"12\"") ("view" . #f) ("node" . "1.5") ("node" . #f)
             ("top" . "0") ("top" . "2.5") ("top" . #f) ("last" . "-3") ("last" . #f)
             ("offset" . "\"5\"") ("offset" . "null") ("offset" . "1e12")
             ("at" . "true") ("at" . #f) ("drawnStart" . "9601") ("drawnEnd" . "[]")
             ("drawnFirst" . "0") ("drawnFirst" . "401") ("drawnLast" . "1.5")
             ("height" . "-1") ("height" . "744.5") ("height" . "2000000")
             ("request" . "-1") ("request" . "null")))
         (check (length (recorded-items 1)) => 1))))

    (test-case "the stream sends the newest screen again while nothing changes"
      (with-tuna
       (lambda ()
         (let* ((stream (open-screen-stream))
                (text (read-until stream (lambda (text) (>= (length (screen-revisions text)) 4))))
                (revisions (screen-revisions text)))
           (Socket-close stream)
           (check (>= (length revisions) 4) => #t)
           ;; Every screen after the first is the same one, sent again.
           (check (length (filter (cut = (car (reverse revisions)) <>) revisions)) ? (cut >= <> 3))))))))
