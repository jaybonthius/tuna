(import (tuna) (test) (test-user) (web) (keys) (tables) (commands) (editing) (kill-ring)
        (echo-area) (clipboard) (web-test tasks))

(define laptop (test-user:client))

(define phone (test-user:open-client))

(define (copies client)
  (map cdr (filter (lambda (call) (equal? "copy" (car call))) (test-user:take-page-calls! client))))

(define (post! client item)
  (web:post-input! client item)
  (test-user:settle))

(test-user:show! "|one two three")

(test "a kill goes to the clipboard of the client whose key made it, and to no other"
  (test-user:press! laptop "M-d")
  (check-equal? '("one") (copies laptop))
  (check-equal? '() (copies phone))
  (test-user:press! phone "C-SPC M-f M-w")
  (check-equal? '(" two") (copies phone))
  (check-equal? '() (copies laptop)))

(test "a kill that no client's input made copies nothing"
  (kill-ring:push! (list "from code"))
  (test-user:settle)
  (check-equal? '() (copies laptop))
  (check-equal? '() (copies phone)))

(test "a paste runs editing's paste in the selected view, and its text is not copied back to the clipboard it came from; the next kill is"
  (post! laptop '(("type" . "paste") ("text" . "pasted ")))
  (check-equal? " twopasted | three" (test-user:text))
  (check-equal? "pasted " (kill-ring:text (kill-ring:current)))
  (check-equal? '() (copies laptop))
  (test-user:press! laptop "M-d")
  (check-equal? '(" three") (copies laptop)))

(test "a paste between keys leaves them pending: after C-u, the next key still takes the prefix argument"
  (test-user:press! laptop "C-u")
  (post! laptop '(("type" . "paste") ("text" . "-")))
  (test-user:press! laptop "x")
  (check-equal? " twopasted -xxxx|" (test-user:text)))

(test "a page with no clipboard, or one whose browser refuses it, says why"
  (post! phone '(("type" . "clipboard") ("outcome" . "unavailable")))
  (check-equal? "Copy failed: the page has no clipboard, which needs HTTPS or localhost" (echo-area:current-message))
  (post! phone '(("type" . "clipboard") ("outcome" . "refused") ("reason" . "NotAllowedError")))
  (check-equal? "Copy failed: the browser refused the clipboard (NotAllowedError)" (echo-area:current-message)))

(test "an item without its text is reported as no clipboard item"
  (let ([reported (append (web-test/tasks:reports-during (lambda () (web:post-input! phone '(("type" . "paste")))))
                          (web-test/tasks:reports-during (lambda () (web:post-input! phone '(("type" . "clipboard") ("outcome" . "refused"))))))])
    (check-equal? '((clipboard "not a clipboard item") (clipboard "not a clipboard item"))
                  (map (lambda (c) (list (condition-who c) (condition-message c))) reported))))

(test "clipboard:copy-to! copies to the clipboard of the client it names, and checks its arguments"
  (clipboard:copy-to! phone "named")
  (check-equal? '("named") (copies phone))
  (check-equal? '() (copies laptop))
  (check-raises (lambda (c) (and (who-condition? c) (eq? 'clipboard:copy-to! (condition-who c)))) (clipboard:copy-to! 'phone "x"))
  (check-raises (lambda (c) (and (who-condition? c) (eq? 'clipboard:copy-to! (condition-who c)))) (clipboard:copy-to! phone 'x)))

(test "pages load the plugin's script, which reads the browser's pastes and writes its clipboard"
  (check-equal? "clipboard/clipboard.js" (tables:ref web:scripts 'clipboard #f)))

(define remapped '())

(commands:define-command (own-paste text)
  "Keeps the text pasted."
  (set! remapped (cons text remapped)))

(test "a paste runs the command the client's keymaps remap editing:paste to"
  (keys:remap! keys:global editing:paste own-paste)
  (post! laptop '(("type" . "paste") ("text" . "elsewhere")))
  (check-equal? '("elsewhere") remapped))
