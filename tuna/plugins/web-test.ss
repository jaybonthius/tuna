;;; The web transport over real loopback HTTP on an ephemeral port: the
;;; launch token, the session cookie, Host and Origin checks, and event
;;; requests: keydowns and pointer items, validated strictly, and the
;;; screen revision pointer items name. A stand-in provides the input the
;;; editor loop needs; another records the items it resolves.
(import :std/test
        :tuna/kernel
        :tuna/services/keys
        :tuna/plugins/web
        "../test-support/web-client"
        (only-in "../test-support/string-input" test-input-plugin test-messages-plugin))
(export web-test)

(def web-plugins
  [test-input-plugin web-transport-plugin])

(def (with-tuna thunk)
  (with-web-tuna web-plugins thunk))

;; An input provider that records every item it resolves, newest first.
(defstruct recording-input (items) final: #t)

(defmethod {resolve! recording-input}
  (lambda (self item)
    (set! (recording-input-items self) (cons item (recording-input-items self)))
    #f))

(defmethod {arrival recording-input}
  (lambda (self item) 'queue))

(def recorded (make-recording-input []))

(defplugin (recording-input-plugin ctx)
  "Records the input items it resolves."
  (context-provide! ctx input-service recorded))

;; The items resolved so far, oldest first, once there are COUNT of them.
(def (recorded-items count)
  (let lp ((tries 300))
    (let (items (call-on-editor-loop (lambda () (recording-input-items recorded))))
      (if (or (>= (length items) count) (zero? tries))
        (reverse items)
        (begin (thread-sleep! 0.01) (lp (- tries 1)))))))

(def (post-json body)
  (reply-status (http "POST" "/commands"
                      headers: [(cons "Datastar-Request" "true")
                                (cons "Content-Type" "application/json")]
                      body: body)))

(def web-test
  (test-suite "tuna/plugins/web"
    (test-case "the launch token is exchanged for an HttpOnly SameSite=Strict cookie"
      (with-tuna
       (lambda ()
         (let (exchange (http "GET" (string-append "/?token=" token) cookie: #f))
           (check (reply-status exchange) => 303)
           (check (reply-header exchange "Location") => "/")
           (let (set-cookie (reply-header exchange "Set-Cookie"))
             (check (and (string-search "HttpOnly" set-cookie) #t) => #t)
             (check (and (string-search "SameSite=Strict" set-cookie) #t) => #t)))
         (let (page (http "GET" "/"))
           (check (reply-status page) => 200)
           (check (and (string-search "id=\"screen\"" (reply-body page)) #t) => #t)
           (check (and (string-search "No renderer is active." (reply-body page)) #t) => #t)))))

    (test-case "requests without the cookie are refused on every route"
      (with-tuna
       (lambda ()
         (for-each (lambda (route)
                     (check (reply-status (http (car route) (cdr route) cookie: #f)) => 403))
                   '(("GET" . "/") ("GET" . "/screen") ("POST" . "/commands")
                     ("GET" . "/static/tuna-input.js") ("GET" . "/elsewhere")))
         (check (reply-status (http "GET" "/?token=wrong" cookie: #f)) => 403)
         (check (reply-status (http "GET" "/" cookie: (string-append session-cookie "0"))) => 403))))

    (test-case "a foreign Host or Origin is refused, even with the cookie"
      (with-tuna
       (lambda ()
         (check (reply-status (http "GET" "/" host: "evil.example")) => 403)
         (check (reply-status (http "GET" "/" host: (string-append "localhost:" (number->string port))))
                => 403)
         (check (reply-status (http "GET" (string-append "/?token=" token) cookie: #f host: "evil.example"))
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

    (test-case "events are acknowledged with 204 and malformed ones refused"
      (with-tuna
       (lambda ()
         (check (reply-status (post-key "a")) => 204)
         (check (reply-status (http "POST" "/commands"
                                    headers: [(cons "Datastar-Request" "true")
                                              (cons "Content-Type" "application/json")]
                                    body: "{\"version\":1,\"type\":\"keydown\"}"))
                => 400)
         (check (reply-status (http "POST" "/commands"
                                    headers: [(cons "Content-Type" "application/json")]
                                    body: (keydown-json "a" #f 2)))
                => 400)
         (check (reply-status (http "POST" "/commands"
                                    headers: [(cons "Datastar-Request" "true")
                                              (cons "Content-Type" "text/plain")]
                                    body: (keydown-json "a" #f 3)))
                => 415))))

    (test-case "key items preserve platform, held Option sides and AltGraph facts"
      (set! (recording-input-items recorded) [])
      (with-web-tuna [test-messages-plugin recording-input-plugin web-transport-plugin]
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

    (test-case "missing or malformed keyboard facts are refused"
      (with-tuna
       (lambda ()
         (check (post-json (keydown-json "x" #f 1)) => 204)
         (for-each
          (lambda (field)
            (for-each (lambda (bad)
                        (check [field bad (post-json (keydown-json "x" #f 2 (cons field bad)))]
                               => [field bad 400]))
                      [#f "null" "0" "1" "\"true\"" "[]" "{}"]))
          ["isMac" "altLeft" "altRight" "altGraph"]))))

    (test-case "each screen carries its revision on its root element"
      (with-tuna
       (lambda ()
         (let (page (reply-body (http "GET" "/")))
           (check (and (string-search "<main data-revision=\"" page) #t) => #t)
           (check (fixnum? (page-revision)) => #t)))))

    (test-case "a pointer item becomes a pointer event: Emacs's button, its part, node and screen"
      (set! (recording-input-items recorded) [])
      (with-web-tuna [test-messages-plugin recording-input-plugin web-transport-plugin]
       (lambda ()
         (let (revision (page-revision))
           (check (post-json (pointer-json (cons "revision" (number->string revision))
                                           (cons "button" "2") (cons "clicks" "2")
                                           (cons "target" "\"status-line:12\"") (cons "node" "4")
                                           (cons "modifiers" "{\"alt\":false,\"ctrl\":true,\"meta\":false,\"shift\":true}")))
                  => 204)
           (check (post-json (pointer-json (cons "node" #f))) => 204)
           (let (items (recorded-items 2))
             (check (length items) => 2)
             (let ((e (car items))
                   (bare (cadr items)))
               (check (pointer-event-client e) => "web-test")
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

    (test-case "malformed and forged pointer items are refused"
      (with-tuna
       (lambda ()
         (check (post-json (pointer-json)) => 204)
         (for-each
           (lambda (change)
             (check [change (post-json (pointer-json change))] => [change 400]))
           '(("version" . "2") ("type" . "\"pointerdown\"") ("kind" . "\"drop\"") ("kind" . #f)
             ("clientId" . "\"web test\"") ("clientId" . "\"\"") ("clientId" . #f)
             ("sequence" . "-1") ("sequence" . "\"1\"")
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
             ("node" . "\"4\"") ("node" . "-4") ("node" . "4.5"))))))))