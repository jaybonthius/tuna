;;; The standard plugins over real loopback HTTP on an ephemeral port.
(import :std/error
        :std/io
        :std/net/address
        :std/test
        :std/time/timeout
        :tuna/kernel
        :tuna/services/echo-area
        :tuna/plugins/keys
        :tuna/plugins/web
        :tuna/plugins/echo-area
        :tuna/plugins/help-panel
        :tuna/plugins/rope
        :tuna/plugins/settings
        :tuna/plugins/buffers
        :tuna/plugins/single-window
        :tuna/plugins/html-renderer
        :tuna/plugins/basic-editing
        :tuna/plugins/demo
        "../test-support/kernel"
        "../test-support/session")
(export web-test)

;;; A minimal HTTP client that controls every header.

(defstruct reply (status headers body) final: #t)

(def (connect port)
  (let (socket (tcp-connect (string->address (string-append "inet4:127.0.0.1:" (number->string port)))))
    (Socket-set-input-timeout! socket (IOTimeout 5))
    socket))

(def (send! socket text)
  (Writer-write (StreamSocket-writer socket) (string->utf8 text)))

(def (request-text method path headers body)
  (string-append
   method " " path " HTTP/1.1\r\n"
   (apply string-append (map (lambda (h) (string-append (car h) ": " (cdr h) "\r\n")) headers))
   "Content-Length: " (number->string (u8vector-length (string->utf8 body))) "\r\n"
   "Connection: close\r\n\r\n"
   body))

;; Read until (DONE? text) or end of input.
(def (read-until socket done?)
  (let ((reader (StreamSocket-reader socket))
        (buffer (make-u8vector 4096)))
    (let lp ((chunks []))
      (let (text (utf8->string (apply u8vector-append (reverse chunks))))
        (if (done? text)
          text
          (let (count (with-catch (lambda (e) (if (premature-end-of-input-error? e) 0 (raise e)))
                                  (lambda () (Reader-read reader buffer 0 4096 1))))
            (if (zero? count)
              text
              (lp (cons (subu8vector buffer 0 count) chunks)))))))))

(def (parse-reply text)
  (let* ((split (string-search "\r\n\r\n" text))
         (head (string-split (substring text 0 split) #\newline))
         (status (string->number (cadr (string-split (car head) #\space)))))
    (make-reply status
                (map (lambda (line)
                       (let (colon (string-index line #\:))
                         (cons (substring line 0 colon)
                               (string-trim-cr (substring line (+ colon 2) (string-length line))))))
                     (cdr head))
                (substring text (+ split 4) (string-length text)))))

(def (string-search needle text)
  (let lp ((i 0))
    (cond
     ((> (+ i (string-length needle)) (string-length text)) #f)
     ((string=? needle (substring text i (+ i (string-length needle)))) i)
     (else (lp (+ i 1))))))

(def (string-trim-cr line)
  (if (and (> (string-length line) 0)
           (char=? (string-ref line (- (string-length line) 1)) #\return))
    (substring line 0 (- (string-length line) 1))
    line))

(def (reply-header reply name)
  (let (pair (find (lambda (h) (string-ci=? (car h) name)) (reply-headers reply)))
    (and pair (cdr pair))))

;;; The running Tuna under test

(def port #f)
(def token #f)
(def session-cookie #f)

(def (host) (string-append "127.0.0.1:" (number->string port)))

(def (http method path headers: (headers []) body: (body "")
           host: (host-header (host)) cookie: (cookie session-cookie))
  (let (socket (connect port))
    (send! socket (request-text method path
                                (append [(cons "Host" host-header)]
                                        (if cookie [(cons "Cookie" cookie)] [])
                                        headers)
                                body))
    (let (text (read-until socket (lambda (text) #f)))
      (Socket-close socket)
      (parse-reply text))))

(def (keydown-json key ctrl? sequence)
  (string-append
   "{\"version\":1,\"type\":\"keydown\",\"clientId\":\"web-test\",\"sequence\":"
   (number->string sequence)
   ",\"key\":\"" key "\",\"code\":\"\",\"location\":0,\"repeat\":false,"
   "\"isComposing\":false,\"altKey\":false,\"ctrlKey\":" (if ctrl? "true" "false")
   ",\"metaKey\":false,\"shiftKey\":false}"))

(def sequence 0)

(def (post-key key ctrl?: (ctrl? #f))
  (set! sequence (+ sequence 1))
  (http "POST" "/commands"
        headers: [(cons "Datastar-Request" "true") (cons "Content-Type" "application/json")]
        body: (keydown-json key ctrl? sequence)))

(def (open-screen-stream)
  (let (socket (connect port))
    (send! socket (request-text "GET" "/screen"
                                [(cons "Host" (host)) (cons "Cookie" session-cookie)
                                 (cons "Datastar-Request" "true")]
                                ""))
    socket))

(def (wait-until ready?)
  (let lp ((tries 300))
    (cond
     ((ready?) #t)
     ((zero? tries) #f)
     (else (thread-sleep! 0.01) (lp (- tries 1))))))

(def standard-plugins
  [keys-plugin web-transport-plugin echo-area-plugin help-panel-plugin
   rope-text-store-plugin settings-plugin no-session-plugin buffers-plugin single-window-plugin
   html-renderer-plugin basic-editing-plugin demo-plugin])

(def (with-tuna thunk)
  (call-with-fresh-kernel standard-plugins
    (lambda ()
      (start-editor-loop! quit-grace: 0.3)
      (let* ((url (web-transport-url))
             (colon (string-index url #\: 7))
             (slash (string-index url #\/ colon)))
        (set! port (string->number (substring url (+ colon 1) slash)))
        (set! token (substring url (+ (string-search "token=" url) 6) (string-length url))))
      (let (exchange (http "GET" (string-append "/?token=" token) cookie: #f))
        (set! session-cookie (car (string-split (reply-header exchange "Set-Cookie") #\;))))
      (thunk))))

(def (settled-message) (call-on-editor-loop current-message))

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
           (check (and (string-search "id=\"screen\"" (reply-body page)) #t) => #t)))))

    (test-case "requests without the cookie are refused on every route"
      (with-tuna
       (lambda ()
         (for-each (lambda (route)
                     (check (reply-status (http (car route) (cdr route) cookie: #f)) => 403))
                   '(("GET" . "/") ("GET" . "/screen") ("POST" . "/commands")
                     ("GET" . "/static/tuna-keyboard.js") ("GET" . "/elsewhere")))
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

    (test-case "every client's stream receives the new screen; C-h s lists the services"
      (with-tuna
       (lambda ()
         (let ((first (open-screen-stream))
               (second (open-screen-stream)))
           (check (and (string-search "datastar-patch-elements" (read-until first (cut string-search "id=\"screen\"" <>))) #t)
                  => #t)
           (post-key "h" ctrl?: #t)
           (post-key "s")
           (for-each
             (lambda (stream)
               (let (text (read-until stream (cut string-search "text-store (live)" <>)))
                 (check (and (string-search "input (startup)  provider: keys-plugin  dependents: " text) #t)
                        => #t)
                 (check (and (string-search "renderer (live)  provider: html-renderer-plugin" text) #t)
                        => #t)
                 (check (and (string-search "text-store (live)  provider: rope-text-store-plugin" text) #t)
                        => #t)
                 (check (and (string-search "display (startup)  provider: web-transport-plugin" text) #t)
                        => #t)))
             [first second])
           (Socket-close first)
           (Socket-close second)))))

    (test-case "C-c l then C-g recovers; so does C-c L, by force"
      (with-tuna
       (lambda ()
         (post-key "c" ctrl?: #t)
         (post-key "l")
         (check (wait-until (lambda () (eq? (current-task-name) 'loop-forever))) => #t)
         (post-key "g" ctrl?: #t)
         (check (settled-message) => "Quit")
         (post-key "c" ctrl?: #t)
         (post-key "L")
         (check (wait-until (lambda () (eq? (current-task-name) 'loop-forever-ignoring-quit))) => #t)
         (post-key "g" ctrl?: #t)
         (check (settled-message) => "Quit (forced: plugin or library state may be inconsistent)")
         (post-key "h" ctrl?: #t)
         (post-key "s")
         (check (settled-message) => ""))))))
