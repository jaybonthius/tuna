(import (tuna) (test) (test-user) (web) (keys) (options) (tables) (buffers) (document) (ask) (browse-url) (web-test tasks))

(define laptop (test-user:client))

(define phone (test-user:open-client))

(define (opened client)
  (map cdr (filter (lambda (call) (equal? "browse-url" (car call))) (test-user:take-page-calls! client))))

(define (raised-by message)
  (lambda (c) (and (who-condition? c) (eq? 'browse-url:open (condition-who c)) (equal? message (condition-message c)))))

(keys:bind! keys:global "C-c u" browse-url:open)

(test "run by a key, browse-url:open asks URL: and opens the answer in a new tab of the browser whose key ran it, and no other"
  (let ([asked '()])
    (options:set! ask:line-reader
      (lambda (question default) (set! asked (cons question asked)) "https://tuna.example/guide"))
    (test-user:press! phone "C-c u")
    (options:unset! ask:line-reader)
    (check-equal? '("URL: ") asked)
    (check-equal? '("https://tuna.example/guide") (opened phone))
    (check-equal? '() (opened laptop))))

(test "code names the client, and an http, https or mailto address opens in any case"
  (browse-url:open "mailto:jay@example.org" laptop)
  (browse-url:open "HTTP://TUNA.EXAMPLE" laptop)
  (browse-url:open "https://tuna.example/a" phone)
  (check-equal? '("mailto:jay@example.org" "HTTP://TUNA.EXAMPLE") (opened laptop))
  (check-equal? '("https://tuna.example/a") (opened phone)))

(test "only http, https and mailto addresses open, only in a client's browser, and nothing opens when one is refused"
  (check-raises (raised-by "not an http, https or mailto address") (browse-url:open "javascript:alert(1)" laptop))
  (check-raises (raised-by "not an http, https or mailto address") (browse-url:open "file:///etc/passwd" laptop))
  (check-raises (raised-by "not an http, https or mailto address") (browse-url:open 'tuna laptop))
  (check-raises (raised-by "not a client") (browse-url:open "https://tuna.example" "laptop"))
  (check-raises (raised-by "no browser to open it in") (browse-url:open "https://tuna.example" #f))
  (check-equal? '() (opened laptop)))

(test "a browser that blocks the new tab says so, and the plugin warns with the address"
  (let ([reported (web-test/tasks:reports-during
                    (lambda () (web:post-input! phone '(("type" . "browse-url") ("url" . "https://tuna.example/guide")))))])
    (check-equal? 1 (length reported))
    (check (warning? (car reported)))
    (check-equal? "The browser blocked the new tab for https://tuna.example/guide" (condition-message (car reported)))))

(test "a browse-url item without an address is reported as not one"
  (let ([reported (web-test/tasks:reports-during (lambda () (web:post-input! phone '(("type" . "browse-url")))))])
    (check-equal? 1 (length reported))
    (check-equal? '(browse-url "not a browse-url item")
                  (list (condition-who (car reported)) (condition-message (car reported))))))

(test "pages load the plugin's script, which opens the tab"
  (check-equal? "browse-url/browse-url.js" (tables:ref web:scripts 'browse-url #f)))

(define notes (buffers:make "notes" "See https://tuna.example/a_(b), (or mailto:jay@example.org). http: alone"))

(define (url-at offset)
  (let-values ([(start end) (browse-url:url-at notes (document:position (buffers:document notes) offset (document:unit characters)))])
    (and start (document:text (buffers:document notes) start end))))

(test "the address at a position, or just after it, is found; punctuation after it and a bracket opened before it are not part of it"
  (check-equal? '(#f "https://tuna.example/a_(b)" "https://tuna.example/a_(b)" "https://tuna.example/a_(b)"
                  "https://tuna.example/a_(b)" "mailto:jay@example.org" "mailto:jay@example.org" #f #f)
                (map url-at '(0 4 10 29 30 36 58 60 71)))
  (let ([aside (buffers:make "aside" "(see https://tuna.example/a)")])
    (check-equal? "https://tuna.example/a"
      (let-values ([(start end) (browse-url:url-at aside 10)])
        (document:text (buffers:document aside) start end)))))

(test "browse-url:url-at checks its arguments"
  (check-raises (lambda (c) (and (who-condition? c) (eq? 'browse-url:url-at (condition-who c)))) (browse-url:url-at 'notes 0))
  (check-raises (lambda (c) (and (who-condition? c) (eq? 'browse-url:url-at (condition-who c)))) (browse-url:url-at notes 1000)))
