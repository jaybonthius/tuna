;;; The web transport over real loopback HTTP on an ephemeral port: the
;;; launch token, the session cookie, Host and Origin checks, and event
;;; requests. Keys provides the input the editor loop needs.
(import :std/test
        :tuna/plugins/keys
        :tuna/plugins/web
        "../test-support/web-client")
(export web-test)

(def web-plugins
  [keys-plugin web-transport-plugin])

(def (with-tuna thunk)
  (with-web-tuna web-plugins thunk))

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
                => 415))))))
