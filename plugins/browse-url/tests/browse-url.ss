(import (tuna) (test) (test-runner) (test-user) (web) (keys) (options) (tables) (buffers) (document) (ask) (editing) (minibuffer)
        (browse-url) (minibuffer-test screen))

(define laptop (test-user:client))

(define phone (test-user:open-client))

(define (opened client)
  (map cdr (filter (lambda (call) (equal? "browse-url" (car call))) (test-user:take-page-calls! client))))


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

(test "with point on an address, browse-url:open offers it, so RET opens it"
  (test-user:show! "see https://tuna.example/gu|ide here")
  (test-user:press! "C-c u")
  (check-equal? '("URL: ") (minibuffer-test/screen:questions))
  (test-user:press! "RET")
  (check-equal? '("https://tuna.example/guide") (opened laptop)))

(test "with a region, browse-url:open offers the region's text over the address at point"
  (test-user:show! "|https://tuna.example/a b")
  (test-user:press! "C-SPC C-e C-c u RET")
  (check-equal? '("https://tuna.example/a b") (opened laptop)))

(test "an address that is not http, https or mailto is refused with a message saying which open, and nothing opens"
  (test-user:show! "|")
  (test-user:press! "C-c u")
  (test-user:type! "ftp://x.example/f")
  (check-equal? '((browse-url:open "Only http, https and mailto addresses open"))
                (test-runner:shown-reports-during (lambda () (test-user:press! "RET"))))
  (check-equal? '() (opened laptop)))

(test "only http, https and mailto addresses open, only in a client's browser, and nothing opens when one is refused"
  (check-raises (test-runner:raised-with 'browse-url:open "Only http, https and mailto addresses open") (browse-url:open "javascript:alert(1)" laptop))
  (check-raises (test-runner:raised-with 'browse-url:open "Only http, https and mailto addresses open") (browse-url:open "file:///etc/passwd" laptop))
  (check-raises (test-runner:raised-with 'browse-url:open "Only http, https and mailto addresses open") (browse-url:open "ftp://x.example/f" laptop))
  (check-raises (test-runner:raised-with 'browse-url:open "not a string") (browse-url:open 'tuna laptop))
  (check-raises (test-runner:raised-with 'browse-url:open "not a client") (browse-url:open "https://tuna.example" "laptop"))
  (check-raises (test-runner:raised-with 'browse-url:open "no browser to open it in") (browse-url:open "https://tuna.example" #f))
  (check-equal? '() (opened laptop)))

(test "a browser that blocks the new tab says so, and the plugin warns with the address"
  (let ([reported (test-runner:reports-during
                    (lambda () (web:post-input! phone '(("type" . "browse-url") ("url" . "https://tuna.example/guide"))) (test-runner:wait-for-batch)))])
    (check-equal? 1 (length reported))
    (check (warning? (car reported)))
    (check-equal? "The browser blocked the new tab for https://tuna.example/guide" (condition-message (car reported)))))

(test "a browse-url item without an address is reported as not one"
  (let ([reported (test-runner:reports-during (lambda () (web:post-input! phone '(("type" . "browse-url"))) (test-runner:wait-for-batch)))])
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

(test "www. and ftp: text is no address"
  (let ([other (buffers:make "other" "www.foo.com ftp://x.example/f")])
    (check-equal? '((#f #f) (#f #f))
      (map (lambda (at) (call-with-values (lambda () (browse-url:url-at other at)) list)) '(4 16)))))

(test "browse-url:url-at checks its arguments"
  (check-raises (lambda (c) (and (who-condition? c) (eq? 'browse-url:url-at (condition-who c)))) (browse-url:url-at 'notes 0))
  (check-raises (lambda (c) (and (who-condition? c) (eq? 'browse-url:url-at (condition-who c)))) (browse-url:url-at notes 1000)))
