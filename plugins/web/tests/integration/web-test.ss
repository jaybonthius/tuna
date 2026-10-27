;;; The web transport over real loopback HTTP on an ephemeral port: the
;;; plain URL, Host and Origin checks, event requests (keydowns, pointer
;;; and scroll items, validated strictly, and the screen revision they
;;; name), the screen stream's re-sends, and tabs (ADR 16): each tab's own
;;; numbering, pacing and screens, and forgetting a tab that went away;
;;; pastes, clipboard reports, and the copy a tab's command asks for. A
;;; stand-in provides the input the editor loop needs; another records the
;;; items it resolves.
(import :std/io
        :std/net/address
        :std/net/uri
        :std/time/timeout
        :std/test
        :tuna/kernel
        :tuna/lib/plugin-options
        :tuna/plugins/clients/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/renderer/contract
        :tuna/plugins/web/plugin
        "../support/web-client"
        :tuna/plugins/editing/contract
        (only-in "../../../../tuna/tests/support/string-input" test-input test-messages current-message))
(export web-test)

(def web-plugins
  [test-input web-transport])

(def (with-tuna thunk)
  (with-web-tuna web-plugins thunk))

;; A renderer whose screen shows SHOWN, so a test decides when the screen
;; changes: the transport sends a screen only when it differs from the last.
;; Each screen is a new object, in parts that split the root's tag name
;; from its attributes, with a newline.
(def shown 0)
(defclass counting-rendering () final: #t)
(defmethod {render-screen counting-rendering}
  (lambda (self c)
    (let (n (number->string shown))
      (vector (string->utf8 "<main")
              (vector (string->utf8 " id=\"screen\">") (string->utf8 (string-append "<p>" n)))
              (string->utf8 (string-append "\n" n "</p></main>"))))))
(defplugin (counting-renderer ctx)
  "Renders a screen that shows a number the test sets."
  provides: [renderer-service]
  (context-provide! ctx renderer-service (Renderer (counting-rendering))))

(def (with-counting-tuna thunk)
  (with-web-tuna [test-input counting-renderer web-transport] thunk))

;; Change the screen and redisplay, on the editor loop.
(def (change-screen!)
  (call-on-editor-loop (lambda () (set! shown (+ shown 1)) (redisplay))))

;; An input provider that runs each key as a command for its client would:
;; the command puts the key's text on the kill ring, which only runs
;; kill-new-hook here.
(defclass copying-keys () final: #t)

(defmethod {resolve! copying-keys}
  (lambda (self item)
    (cons 'kill (lambda ()
                  (parameterize ((current-client (key-event-client item)))
                    (run-hook kill-new-hook (key-event-key item)))))))

(defmethod {arrival copying-keys}
  (lambda (self item) 'queue))

(defplugin (copying-input ctx)
  "Runs kill-new-hook with each key's text, for the key's client."
  provides: [input-service]
  (context-provide! ctx input-service (copying-keys)))

;; How many times NEEDLE is in TEXT.
(def (occurrences needle text)
  (let lp ((from 0) (n 0))
    (let (at (string-search-from needle text from))
      (if at (lp (+ at 1) (+ n 1)) n))))

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

;; An item as JSON, from FIELDS with the fields in CHANGES, each (name .
;; raw-json), or (name . #f) to leave the field out.
(def (item-json fields changes)
  (let (merged (filter cdr (map (lambda (field) (or (assoc (car field) changes) field)) fields)))
    (string-append
     "{"
     (string-join (map (lambda (field) (string-append "\"" (car field) "\":" (cdr field))) merged) ",")
     "}")))

;; A scroll item as JSON from the current tab: view 12's scroller drawing
;; node 4, measured on screen 0 after placement 2: line item "4.61.0" at
;; the top, 5.5 px above the edge, not in a spacer, and "4.95.0" the last
;; in view.
(def (scroll-json . changes)
  (item-json `(("version" . "1") ("tab" . ,(string-append "\"" (current-tab) "\""))
               ("type" . "\"scroll\"") ("sequence" . "1") ("revision" . "0")
               ("view" . "12") ("node" . "4") ("placement" . "2")
               ("top" . "\"4.61.0\"") ("offset" . "5.5") ("lastVisible" . "\"4.95.0\"")
               ("spacer" . "null") ("spacerDistance" . "0")
               ("before" . "100") ("after" . "400") ("drawnHeight" . "39744.25")
               ("above" . "20000.25") ("below" . "19000")
               ("width" . "800") ("height" . "744") ("settled" . "true"))
             changes))

;; Whether TEXT holds a screen.
(def (has-screen? text) (pair? (screen-revisions text)))

;; A test that TEXT holds a screen newer than every screen in OLD.
(def (newer-than old)
  (let (revision (apply max (screen-revisions old)))
    (lambda (text) (any (cut > <> revision) (screen-revisions text)))))

(def (seconds-since start) (- (time->seconds (current-time)) start))

(def (wait-until ready?)
  (let lp ((tries 300))
    (cond
     ((ready?) #t)
     ((zero? tries) #f)
     (else (thread-sleep! 0.01) (lp (- tries 1))))))

(def (quoted text) (string-append "\"" text "\""))

;; The clients client-gone-hook ran for, newest first, each as its id and
;; the task the hook ran in.
(def gone [])

(defplugin (gone-recorder ctx)
  "Records the clients that went away."
  (context-add-hook! ctx client-gone-hook 'gone-recorder
                     (lambda (c) (set! gone (cons [(client-id c) (current-task-name)] gone)))))

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

    (test-case "the head links the icons and the manifest; /favicon.ico is served, from the icons option's folder"
      (with-tuna
       (lambda ()
         (let (page (reply-body (http "GET" "/")))
           (for-each (lambda (link) (check (and (string-search link page) #t) => #t))
                     ["<link rel=\"icon\" href=\"/icons/favicon.ico\""
                      "<link rel=\"icon\" href=\"/icons/favicon-32x32.png\" sizes=\"32x32\" type=\"image/png\">"
                      "<link rel=\"apple-touch-icon\" href=\"/icons/apple-touch-icon.png\""
                      "<link rel=\"manifest\" href=\"/icons/site.webmanifest\">"]))
         (let (reply (http-bytes "/favicon.ico"))
           (check (reply-status reply) => 200)
           (check (reply-header reply "Content-Type") => "image/vnd.microsoft.icon"))
         (check (reply-header (http-bytes "/icons/android-chrome-512x512.png") "Content-Type") => "image/png")
         (let (reply (http "GET" "/icons/site.webmanifest"))
           (check (reply-header reply "Content-Type") => "application/manifest+json")
           (check (and (string-search "\"name\":\"Tuna\"" (reply-body reply)) #t) => #t))
         (check (reply-status (http "GET" "/icons/../plugin.ss")) => 404)))
      (let (folder (path-expand (string-append "tuna-icons-" (number->string (random-integer 1000000000)))
                                (or (getenv "TMPDIR" #f) "/tmp")))
        (create-directory folder)
        (call-with-output-file (path-expand "favicon.ico" folder) (cut write-u8vector (u8vector 1 2 3) <>))
        (set-plugin-options! web-transport [(cons 'icons folder)])
        (unwind-protect
          (with-tuna
           (lambda ()
             (check (reply-body (http-bytes "/favicon.ico")) => (u8vector 1 2 3))
             (check (reply-status (http "GET" "/icons/site.webmanifest")) => 404)))
          (set-plugin-options! web-transport [])
          (delete-file-or-directory folder #t))))

    (test-case "a foreign Host or Origin is refused on every route"
      (with-tuna
       (lambda ()
         (for-each
          (lambda (path)
            (check (reply-status (http "POST" path host: "evil.example")) => 403)
            (check (reply-status (http "POST" path headers: [(cons "Origin" "http://evil.example")])) => 403))
          ["/" "/screen" "/commands" "/static/tuna-input.js"])
         (check (reply-status (http "GET" "/" host: "localhost")) => 403)
         (check (reply-status (http "GET" "/" headers: [(cons "Origin" "http://evil.example")])) => 403)
         (check (reply-status (http "POST" "/commands"
                                    headers: [(cons "Origin" "http://evil.example")
                                              (cons "Datastar-Request" "true")
                                              (cons "Content-Type" "application/json")]
                                    body: (keydown-json "a" #f 1)))
                => 403)
         (check (reply-status (http "GET" "/" headers: [(cons "Origin" (string-append "http://" (host)))]))
                => 200))))

    (test-case "loopback by either name, and the hosts option's names, are accepted with http or https"
      (set-plugin-options! web-transport [(cons 'hosts ["me.example.ts.net"])])
      (unwind-protect
        (with-tuna
         (lambda ()
           (let (localhost (string-append "localhost:" (number->string port)))
             (check (reply-status (http "GET" "/" host: localhost)) => 200)
             (check (reply-status (http "GET" "/" host: localhost
                                        headers: [(cons "Origin" (string-append "http://" localhost))]))
                    => 200))
           (check (reply-status (http "GET" "/" host: "me.example.ts.net"
                                      headers: [(cons "Origin" "https://me.example.ts.net")]))
                  => 200)
           (check (reply-status (http "GET" "/" host: "me.example.ts.net"
                                      headers: [(cons "Origin" "https://evil.example")]))
                  => 403)
           (check (reply-status (http "GET" "/" host: "other.example.ts.net")) => 403)))
        (set-plugin-options! web-transport [])))

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
         ;; A tab's first item sets where its numbering starts.
         (check (post-json (keydown-json "a" #f 1)) => 204)
         (check (post-json (keydown-json "c" #f 3)) => 204)
         (check (post-json (keydown-json "duplicate" #f 3)) => 204)
         (check (post-json (pointer-json (cons "sequence" "2"))) => 204)
         (check (post-json (keydown-json "duplicate" #f 1)) => 204)
         (let (items (recorded-items 3))
           (check (length items) => 3)
           (check (key-event-key (car items)) => "a")
           (check (pointer-event? (cadr items)) => #t)
           (check (key-event-key (caddr items)) => "c")))))

    (test-case "a new page's first item may arrive after its second: the server made its tab, from 1"
      (set! (input-recorder-items recorded) [])
      (with-web-tuna [test-messages recording-input web-transport]
       (lambda ()
         (let* ((first (current-tab))
                (second (new-tab!)))
           (check (equal? first second) => #f)
           (check (post-json (keydown-json "b" #f 2)) => 204)
           (check (post-json (keydown-json "a" #f 1)) => 204)
           (check (map key-event-key (recorded-items 2)) => ["a" "b"])))))

    (test-case "a page reload is a new tab, numbered on its own; the old tab keeps its order"
      (set! (input-recorder-items recorded) [])
      (with-web-tuna [test-messages recording-input web-transport]
       (lambda ()
         (let (old (current-tab))
           (check (post-json (keydown-json "a" #f 1)) => 204)
           (check (post-json (keydown-json "old" #f 3)) => 204)
           (check (reply-status (http "GET" "/")) => 200)
           (new-tab!)
           (check (post-json (keydown-json "b" #f 1)) => 204)
           (check (post-json (keydown-json "c" #f 2)) => 204)
           (check (map key-event-key (recorded-items 3)) => ["a" "b" "c"])
           (check (post-json (keydown-json "a2" #f 2 (cons "tab" (string-append "\"" old "\"")))) => 204)
           (check (map key-event-key (recorded-items 5)) => ["a" "b" "c" "a2" "old"])))))

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
         (check (post-json (keydown-json "first" #f 1)) => 204)
         (let lp ((sequence 3))
           (when (<= sequence 67)
             (check (post-json (keydown-json (number->string sequence) #f sequence)) => 204)
             (lp (+ sequence 1))))
         ;; The missing item arriving late is ignored, still with 204.
         (check (post-json (keydown-json "late" #f 2)) => 204)
         (check (post-json (keydown-json "after" #f 68)) => 204)
         (let (keys (map key-event-key (recorded-items 67)))
           (check (car keys) => "first")
           (check (cadr keys) => "3")
           (check (list-ref keys 65) => "67")
           (check (list-ref keys 66) => "after")
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

    (test-case "a paste item becomes a paste event, its line ends made newlines; a clipboard report shows its message and submits nothing"
      (set! (input-recorder-items recorded) [])
      (with-web-tuna [test-messages recording-input web-transport]
       (lambda ()
         (let (message-is (lambda (text)
                            (wait-until (lambda () (equal? (call-on-editor-loop current-message) text)))))
           (check (reply-status (post-paste "\"a\\r\\nb\\rc\"")) => 204)
           (check (reply-status (post-paste "5")) => 204)
           (check (reply-status (post-clipboard-report "\"unavailable\"")) => 204)
           (check (message-is "On the kill ring only: the browser gives the clipboard only to HTTPS and localhost pages")
                  => #t)
           (check (reply-status (post-clipboard-report "\"refused\"" reason: "\"NotAllowedError\"")) => 204)
           (check (message-is "On the kill ring only: the browser refused the clipboard (NotAllowedError)") => #t)
           (check (reply-status (post-clipboard-report "\"refused\"" reason: "\"<b>\"")) => 204)
           (check (reply-status (post-clipboard-report "\"lost\"")) => 204)
           (check (reply-status (post-key "x")) => 204)
           (let (items (recorded-items 2))
             (check (map (lambda (item) (if (paste-event? item) (paste-event-text item) (key-event-key item))) items)
                    => ["a\nb\nc" "x"])
             (check (map (lambda (item) (if (paste-event? item) (paste-event-sequence item) (key-event-sequence item)))
                         items)
                    => [1 7]))
           (check (call-on-editor-loop current-message)
                  => "On the kill ring only: the browser refused the clipboard (NotAllowedError)")))))

    (test-case "a text a tab's command puts on the kill ring is copied by that tab alone, once, after its next screen"
      (with-web-tuna [test-messages copying-input counting-renderer web-transport]
       (lambda ()
         (let* ((a (current-tab))
                (b (new-tab!))
                (a-stream (open-screen-stream tab: a))
                (b-stream (open-screen-stream tab: b))
                (a-first (read-until a-stream has-screen?))
                (b-first (read-until b-stream has-screen?)))
           (check (reply-status (post-applied (applied-path a-first) tab: a)) => 204)
           (check (reply-status (post-applied (applied-path b-first) tab: b)) => 204)
           ;; Tab A's key kills a\r<b>; nothing on the screen changes.
           (check (reply-status (post-key "a\\r<b>" tab: a)) => 204)
           (let (text (read-until a-stream (cut string-search "tunaCopy" <>)))
             (check ((newer-than a-first) text) => #t)
             (check (occurrences "@tunaCopy()" text) => 1)
             (check (and (string-search "data: selector body\ndata: mode append\n" text) #t) => #t)
             (check (and (string-search "\"a\\r&lt;b&gt;\"" text) #t) => #t))
           ;; A's unconfirmed screen is sent again after a second, without
           ;; the copy; B gets nothing.
           (let (again (read-until a-stream (lambda (text) #f) seconds: 1.5))
             (check (has-screen? again) => #t)
             (check (occurrences "tunaCopy" again) => 0))
           (Socket-set-input-timeout! b-stream (IOTimeout 1.5))
           (check (occurrences "tunaCopy" (with-catch (lambda (e) "")
                                                      (lambda () (read-until b-stream (lambda (text) #f) seconds: 1.5))))
                  => 0)
           (Socket-close a-stream)
           (Socket-close b-stream)))))

    (test-case "each screen carries its revision on its root element"
      (with-tuna
       (lambda ()
         (let (page (reply-body (http "GET" "/")))
           (check (and (string-search "<main data-revision=\"" page) #t) => #t)
           (check (fixnum? (page-revision)) => #t)))))

    (test-case "a pointer item becomes a pointer event: Emacs's button, its part, node, line and screen"
      (set! (input-recorder-items recorded) [])
      (with-web-tuna [test-messages recording-input web-transport]
       (lambda ()
         (let (revision (page-revision))
           (check (post-json (pointer-json (cons "revision" (number->string revision))
                                           (cons "button" "2") (cons "clicks" "2")
                                           (cons "target" "\"status-line:12\"") (cons "node" "4")
                                           (cons "line" "{\"item\":\"4.12.3\",\"charsRevision\":9,\"column\":15}")
                                           (cons "modifiers" "{\"alt\":false,\"ctrl\":true,\"meta\":false,\"shift\":true}")))
                  => 204)
           (check (post-json (pointer-json (cons "sequence" "2") (cons "node" #f))) => 204)
           (for-each (lambda (kind sequence)
                       (check (post-json (pointer-json (cons "kind" (quoted kind)) (cons "sequence" sequence))) => 204))
                     '("down" "movement" "drag") '("3" "4" "5"))
           (check (map pointer-event-kind (recorded-items 5)) => '(click click down movement drag))
           (let (items (recorded-items 2))
             (let ((e (car items))
                   (bare (cadr items)))
               (check (pointer-event-button e) => 3)
               (check (pointer-event-clicks e) => 2)
               (check [(pointer-event-alt? e) (pointer-event-ctrl? e)
                       (pointer-event-meta? e) (pointer-event-shift? e)]
                      => [#f #t #f #t])
               (check (pointer-event-names e) => ["C-S-double-mouse-3" "C-S-mouse-3"])
               (let (p (pointer-event-start e))
                 (check [(posn-area p) (posn-part p) (posn-node-id p) (posn-revision p)
                         (posn-line p) (posn-line-revision p) (posn-column p)]
                        => ['status-line 12 4 revision "4.12.3" 9 15]))
               (check (posn-node-id (pointer-event-start bare)) => #f)
               (check (posn-line (pointer-event-start bare)) => #f)
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
             ("node" . "\"4\"") ("node" . "-4") ("node" . "4.5")
             ("line" . "\"4.12.3\"") ("line" . "{}")
             ("line" . "{\"item\":\"4.x.3\",\"charsRevision\":9,\"column\":15}")
             ("line" . "{\"item\":\"4.12.3\",\"charsRevision\":-1,\"column\":15}")
             ("line" . "{\"item\":\"4.12.3\",\"charsRevision\":9,\"column\":1.5}")
             ("line" . "{\"item\":\"4.12.3\",\"column\":15}")))
         (check (length (recorded-items 1)) => 1))))

    (test-case "a scroll item becomes a scroll event naming its view, scroller and screen"
      (set! (input-recorder-items recorded) [])
      (with-web-tuna [test-messages recording-input web-transport]
       (lambda ()
         (let (revision (page-revision))
           (check (post-json (scroll-json (cons "revision" (number->string revision)))) => 204)
           (check (post-json (scroll-json (cons "sequence" "2") (cons "top" "null") (cons "lastVisible" "null")
                                          (cons "placement" "0"))) => 204)
           (check (post-json (scroll-json (cons "sequence" "3") (cons "spacer" "\"below\"")
                                          (cons "spacerDistance" "1234.5") (cons "lastVisible" "null"))) => 204)
           (let (items (recorded-items 3))
             (check (length items) => 3)
             (let ((e (car items))
                   (bare (cadr items))
                   (spaced (caddr items)))
               (let (p (scroll-event-start e))
                 (check [(posn-area p) (posn-part p) (posn-node-id p) (posn-revision p)]
                        => ['view 12 4 revision]))
               (check [(scroll-event-placement e) (scroll-event-top-item e) (scroll-event-top-offset e)
                       (scroll-event-last-visible-item e)]
                      => [2 "4.61.0" 5.5 "4.95.0"])
               (check [(scroll-event-spacer e) (scroll-event-spacer-distance e)] => [#f 0.])
               (check [(scroll-event-drawn-before e) (scroll-event-drawn-after e) (scroll-event-drawn-height e)
                       (scroll-event-px-above e) (scroll-event-px-below e)]
                      => [100 400 39744.25 20000.25 19000.])
               (check [(scroll-event-spacer spaced) (scroll-event-spacer-distance spaced)
                       (scroll-event-top-item spaced) (scroll-event-last-visible-item spaced)]
                      => ['below 1234.5 "4.61.0" #f])
               (check [(scroll-event-viewport-width e) (scroll-event-viewport-height e)] => [800 744])
               (check [(scroll-event-top-item bare) (scroll-event-last-visible-item bare)
                       (scroll-event-placement bare)]
                      => [#f #f 0])))))))

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
             ("placement" . "-1") ("placement" . "null") ("placement" . #f)
             ("top" . "61") ("top" . "\"\"") ("top" . "\"4-61\"") ("top" . "\"4.61.0;\"")
             ("top" . "\"11111111111111111111111111111111111111111111111111111111111111111\"")
             ("top" . #f) ("lastVisible" . "4") ("lastVisible" . #f)
             ("offset" . "\"5\"") ("offset" . "null") ("offset" . "1e12")
             ("spacer" . "\"middle\"") ("spacer" . "\"Above\"") ("spacer" . "1") ("spacer" . #f)
             ("spacerDistance" . "-1") ("spacerDistance" . "\"3\"") ("spacerDistance" . "null")
             ("spacerDistance" . #f)
             ("before" . "-1") ("before" . "1.5") ("after" . "\"4\"") ("after" . #f)
             ("drawnHeight" . "-0.5") ("drawnHeight" . "1e12") ("drawnHeight" . #f)
             ("above" . "true") ("above" . "-1") ("above" . #f) ("below" . "[]") ("below" . "-3")
             ("settled" . "null") ("settled" . "1") ("settled" . "\"true\"") ("settled" . #f)
             ("width" . "-1") ("width" . #f)
             ("height" . "-1") ("height" . "744.5") ("height" . "2000000")))
         (check (length (recorded-items 1)) => 1))))

    (test-case "a scroll item in a spacer must name the drawn item next to it"
      (set! (input-recorder-items recorded) [])
      (with-web-tuna [test-messages recording-input web-transport]
       (lambda ()
         (check (post-json (scroll-json)) => 204)
         (check (post-json (scroll-json (cons "sequence" "2") (cons "spacer" "\"above\"") (cons "top" "null")))
                => 204)
         (check (post-json (scroll-json (cons "sequence" "3"))) => 204)
         (check (map scroll-event-sequence (recorded-items 2)) => [1 3]))))

    (test-case "a rejected item does not hold up the items after it"
      (set! (input-recorder-items recorded) [])
      (with-web-tuna [test-messages recording-input web-transport]
       (lambda ()
         (check (post-json (scroll-json)) => 204)
         (check (post-json (scroll-json (cons "sequence" "2") (cons "height" "-1"))) => 204)
         (check (post-json (scroll-json (cons "sequence" "3"))) => 204)
         (check (length (recorded-items 2)) => 2))))

    (test-case "an input request is answered only once its body has arrived"
      (set! (input-recorder-items recorded) [])
      (with-web-tuna [test-messages recording-input web-transport]
       (lambda ()
         (let* ((body (scroll-json))
                (socket (tcp-connect (string->address (string-append "inet4:" (host)))))
                (send (lambda (text) (Writer-write (StreamSocket-writer socket) (string->utf8 text)))))
           ;; Safari often sends the headers and the body in separate
           ;; packets; an answer before the body would close the connection
           ;; on it.
           (send (string-append "POST /commands HTTP/1.1\r\nHost: " (host) "\r\n"
                                "Datastar-Request: true\r\nContent-Type: application/json\r\n"
                                "Content-Length: " (number->string (u8vector-length (string->utf8 body)))
                                "\r\nConnection: close\r\n\r\n"))
           (Socket-set-input-timeout! socket (IOTimeout 0.3))
           (check (with-catch (lambda (e) 'no-answer)
                              (lambda () (Reader-read (StreamSocket-reader socket) (make-u8vector 64) 0 64 1)))
                  => 'no-answer)
           (Socket-set-input-timeout! socket (IOTimeout 5))
           (send body)
           (check (string-prefix? "HTTP/1.1 204" (read-until socket (lambda (text) #f))) => #t)
           (Socket-close socket)
           (check (length (recorded-items 1)) => 1)))))

    (test-case "a screen's event: its parts in order, data-init then data-revision after the tag name"
      (with-counting-tuna
       (lambda ()
         (let* ((stream (open-screen-stream))
                (text (read-until stream (lambda (text) (string-search "</main>\n\n" text))))
                (revision (car (screen-revisions text)))
                (stream-number (let* ((path (applied-path text))
                                      (from (+ (string-search "stream=" path) 7)))
                                 (substring path from (string-index path #\& from))))
                (n (number->string shown))
                (event (string-append
                        "event: datastar-patch-elements\n"
                        "data: elements <main data-init=\"@post('/applied?stream=" stream-number
                        "&amp;count=1'); el.removeAttribute('data-init')\" data-revision=\""
                        (number->string revision) "\" id=\"screen\"><p>" n "\n"
                        "data: elements " n "</p></main>\n\n")))
           (check (and (string-search event text) #t) => #t)
           ;; The page shows the screen with its revision only.
           (let (page (reply-body (http "GET" "/")))
             (check (and (string-search (string-append "<body><main data-revision=\"") page) #t) => #t)
             (check (and (string-search (string-append "\" id=\"screen\"><p>" n "\n" n "</p></main></body></html>") page) #t)
                    => #t))
           (Socket-close stream)))))

    (test-case "reading a stream for a screen that never comes stops at its deadline"
      (with-counting-tuna
       (lambda ()
         (let* ((stream (open-screen-stream))
                (started (time->seconds (current-time)))
                (text (read-until stream (lambda (text) #f) seconds: 2)))
           (check (has-screen? text) => #t)
           (check (< (seconds-since started) 4) => #t)
           (Socket-close stream)))))

    (test-case "a redisplay that changes nothing on screen sends nothing"
      (with-counting-tuna
       (lambda ()
         (let* ((stream (open-screen-stream))
                (first (read-until stream (lambda (text) (pair? (screen-revisions text))))))
           (check (reply-status (post-applied (applied-path first))) => 204)
           ;; Nothing changed: no new screen, only keep-alives at most.
           (call-on-editor-loop redisplay)
           (call-on-editor-loop redisplay)
           (Socket-set-input-timeout! stream (IOTimeout 1.5))
           (let (text (with-catch (lambda (e) "") (lambda () (read-until stream (lambda (text) (pair? (screen-revisions text)))))))
             (check (screen-revisions text) => []))
           ;; A change is sent.
           (Socket-set-input-timeout! stream (IOTimeout 5))
           (change-screen!)
           (check (pair? (screen-revisions (read-until stream (lambda (text) (pair? (screen-revisions text))))))
                  => #t)
           (Socket-close stream)))))

    (test-case "a page gets a newer screen once it confirms the last, or after the timeout"
      (with-counting-tuna
       (lambda ()
         (let* ((stream (open-screen-stream))
                (first (read-until stream (lambda (text) (pair? (screen-revisions text)))))
                (revision (car (screen-revisions first)))
                (newer? (lambda (text) (any (cut > <> revision) (screen-revisions text))))
                (started (time->seconds (current-time))))
           ;; Unconfirmed: the newer screen waits for the timeout (1 s).
           (change-screen!)
           (let (text (read-until stream newer?))
             (check (newer? text) => #t)
             (check (> (- (time->seconds (current-time)) started) 0.8) => #t)
             ;; Confirmed: the next newer screen comes at once.
             (set! revision (apply max (screen-revisions text)))
             (check (reply-status (post-applied (applied-path text))) => 204)
             (let (confirmed (time->seconds (current-time)))
               (change-screen!)
               (check (newer? (read-until stream newer?)) => #t)
               (check (< (- (time->seconds (current-time)) confirmed) 0.5) => #t)))
           (Socket-close stream)))))

    (test-case "two tabs are numbered on their own: a tab opening loses or reorders none of another's input"
      (set! (input-recorder-items recorded) [])
      (with-web-tuna [test-messages recording-input web-transport]
       (lambda ()
         (let* ((a (current-tab))
                (a-stream (open-screen-stream tab: a)))
           (for-each (lambda (key) (post-key key tab: a)) ["a1" "a2" "a3"])
           ;; Tab B loads and counts from 1 while A is at 3.
           (check (reply-status (http "GET" "/")) => 200)
           (let* ((b (new-tab!))
                  (b-stream (open-screen-stream tab: b)))
             (post-key "b1" tab: b)
             (post-key "a4" tab: a)
             (post-key "b2" tab: b)
             (post-key "a5" tab: a)
             ;; Each tab's items are put in order on their own.
             (check (post-json (keydown-json "a7" #f 7 (cons "tab" (quoted a)))) => 204)
             (check (post-json (keydown-json "a6" #f 6 (cons "tab" (quoted a)))) => 204)
             (let* ((items (recorded-items 9))
                    (from (lambda (id)
                            (filter (lambda (e) (equal? (client-id (key-event-client e)) id)) items))))
               (check (length items) => 9)
               (check (map key-event-key (from a)) => ["a1" "a2" "a3" "a4" "a5" "a6" "a7"])
               (check (map key-event-key (from b)) => ["b1" "b2"])
               ;; One client per tab.
               (check (andmap (lambda (e) (eq? (key-event-client e) (key-event-client (car (from a)))))
                              (from a))
                      => #t)
               (check (eq? (key-event-client (car (from a))) (key-event-client (car (from b)))) => #f))
             (Socket-close a-stream)
             (Socket-close b-stream))))))

    (test-case "items and streams without a valid tab id are rejected"
      (set! (input-recorder-items recorded) [])
      (with-web-tuna [test-messages recording-input web-transport]
       (lambda ()
         (check (post-json (keydown-json "x" #f 1)) => 204)
         (for-each
          (lambda (bad)
            (check [bad (post-json (keydown-json "y" #f 2 (cons "tab" bad)))] => [bad 204]))
          [#f "null" "\"\"" "5" "[]" "{}" "\"tab one\"" "\"tab/1\"" "\"é\""
           (quoted (make-string 65 #\a))])
         (check (post-json (keydown-json "z" #f 2)) => 204)
         (check (post-json (keydown-json "w" #f 1 (cons "tab" (quoted (make-string 64 #\a))))) => 204)
         (check (map key-event-key (recorded-items 3)) => ["x" "z" "w"])
         (for-each
          (lambda (path)
            (check [path (reply-status (http "GET" path headers: [(cons "Datastar-Request" "true")]))]
                   => [path 400]))
          ["/screen"
           (string-append "/screen?datastar=" (uri-encode "{}"))
           (string-append "/screen?datastar=" (uri-encode "{\"tab\":\"tab one\"}"))
           (string-append "/screen?datastar=" (uri-encode "{\"tab\":5}"))]))))

    (test-case "each tab's screens are paced by its own confirmations"
      (with-counting-tuna
       (lambda ()
         (let* ((a (current-tab))
                (b (new-tab!))
                (a-stream (open-screen-stream tab: a))
                (b-stream (open-screen-stream tab: b))
                (a-first (read-until a-stream has-screen?))
                (b-first (read-until b-stream has-screen?))
                (started (time->seconds (current-time))))
           ;; A confirms its screen; B does not, so B's next waits for the
           ;; timeout (1 s) while A's comes at once.
           (check (reply-status (post-applied (applied-path a-first) tab: a)) => 204)
           (change-screen!)
           (check ((newer-than a-first) (read-until a-stream (newer-than a-first))) => #t)
           (check (< (seconds-since started) 0.5) => #t)
           (check ((newer-than b-first) (read-until b-stream (newer-than b-first))) => #t)
           (check (> (seconds-since started) 0.8) => #t)
           (Socket-close a-stream)
           (Socket-close b-stream)))))

    (test-case "a scroll report gets its own tab a screen even when nothing changed, and no other tab"
      (set! (input-recorder-items recorded) [])
      (with-web-tuna [test-messages recording-input counting-renderer web-transport]
       (lambda ()
         (let* ((a (current-tab))
                (b (new-tab!))
                (a-stream (open-screen-stream tab: a))
                (b-stream (open-screen-stream tab: b))
                (a-first (read-until a-stream has-screen?))
                (b-first (read-until b-stream has-screen?))
                (nothing-on (lambda (stream)
                              (Socket-set-input-timeout! stream (IOTimeout 1.5))
                              (let (text (with-catch (lambda (e) "")
                                                     (lambda () (read-until stream has-screen?))))
                                (Socket-set-input-timeout! stream (IOTimeout 5))
                                (screen-revisions text)))))
           (check (reply-status (post-applied (applied-path a-first) tab: a)) => 204)
           (check (reply-status (post-applied (applied-path b-first) tab: b)) => 204)
           (check (post-json (scroll-json (cons "tab" (quoted a)))) => 204)
           (let (text (read-until a-stream (newer-than a-first)))
             (check ((newer-than a-first) text) => #t)
             (check (reply-status (post-applied (applied-path text) tab: a)) => 204))
           (check (nothing-on b-stream) => [])
           ;; A rejected report is answered too, again only in its own tab.
           (check (post-json (scroll-json (cons "tab" (quoted b)) (cons "height" "-1"))) => 204)
           (let (b-second (read-until b-stream (newer-than b-first)))
             (check ((newer-than b-first) b-second) => #t)
             (check (nothing-on a-stream) => [])
             (check (length (recorded-items 1)) => 1)
             ;; A pointer movement is answered the same way.
             (check (reply-status (post-applied (applied-path b-second) tab: b)) => 204)
             (check (post-json (pointer-json (cons "tab" (quoted b)) (cons "sequence" "2")
                                             (cons "kind" "\"movement\"")))
                    => 204)
             (check ((newer-than b-second) (read-until b-stream (newer-than b-second))) => #t))
           (check (nothing-on a-stream) => [])
           (Socket-close a-stream)
           (Socket-close b-stream)))))

    (test-case "a tab whose streams all closed is forgotten after the grace period; one reopened in time is kept"
      (set! (input-recorder-items recorded) [])
      (set! gone [])
      (set-plugin-options! web-transport [(cons 'screen-timeout 50) (cons 'tab-grace 300)])
      (unwind-protect
        (with-web-tuna [test-messages recording-input web-transport gone-recorder]
         (lambda ()
           (let* ((a (current-tab))
                  (b (new-tab!))
                  (a-stream (open-screen-stream tab: a))
                  (b-stream (open-screen-stream tab: b)))
             (read-until a-stream has-screen?)
             (read-until b-stream has-screen?)
             (post-key "a1" tab: a)
             (post-key "b1" tab: b)
             (check (map key-event-key (recorded-items 2)) => ["a1" "b1"])
             ;; A closes for good; B's stream closes and reopens, as when a
             ;; hidden browser tab is shown again.
             (Socket-close a-stream)
             (Socket-close b-stream)
             (let (b-again (open-screen-stream tab: b))
               (read-until b-again has-screen?)
               ;; The hook runs on the editor loop, as a task.
               (check (wait-until (lambda () (pair? gone))) => #t)
               (check gone => [[a 'forget-tab]])
               (thread-sleep! 0.5)
               (check (map car gone) => [a])
               ;; B kept its numbering, so its 3 waits for its 2. A comes
               ;; back as a new tab, whose first item sets its numbering.
               (check (post-json (keydown-json "b3" #f 3 (cons "tab" (quoted b)))) => 204)
               (check (post-json (keydown-json "b2" #f 2 (cons "tab" (quoted b)))) => 204)
               (check (post-json (keydown-json "a5" #f 5 (cons "tab" (quoted a)))) => 204)
               (check (map key-event-key (recorded-items 5)) => ["a1" "b1" "b2" "b3" "a5"])
               (Socket-close b-again)))))
        (set-plugin-options! web-transport [])))))

;; The /applied path of the last screen in TEXT, as its data-init posts it.
(def (applied-path text)
  (let lp ((at 0) (last #f))
    (let (found (string-search-from "/applied?stream=" text at))
      (if found
        (lp (+ found 1) found)
        (let (end (string-index text #\' last))
          (unescape-ampersands (substring text last end)))))))

(def (unescape-ampersands text)
  (let (at (string-search "&amp;" text))
    (if at
      (string-append (substring text 0 (+ at 1))
                     (unescape-ampersands (substring text (+ at 5) (string-length text))))
      text)))

(def (string-search-from needle text start)
  (let (at (string-search needle (substring text start (string-length text))))
    (and at (+ start at))))
