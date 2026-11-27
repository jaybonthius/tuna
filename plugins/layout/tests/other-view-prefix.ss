(import (tuna) (test) (test-runner) (test-user) (keys) (commands) (buffers) (views) (layout) (layout-split) (web) (editing) (minibuffer)
        (completion-list) (buffer-picker) (file-picker) (command-picker) (completion-test picking)
        (file-picker-test tree))

(define (shown)
  (map (lambda (v) (list (buffers:name (views:buffer v)) (eq? v (layout:selected-view))))
       (remp (lambda (v) (buffers:internal-name? (buffers:name (views:buffer v)))) (layout:views))))

(define (description) (keys:prefix-description (test-user:client)))

(define notes (buffers:make "notes" "one\ntwo\n"))

(define elsewhere (buffers:make "elsewhere" "x\n"))

(define (start!)
  (layout:reset-layout)
  (layout:switch-to-buffer notes))

(define (switch-by-name! name)
  (test-user:press! "C-x b")
  (test-user:type! name)
  (completion-test/picking:choices)
  (test-user:press! "RET"))

(test "C-x 4 4 waits for the next command, whose own prompt still shows at the bottom, and shows its buffer in another view, which it selects; deleting that view selects the one beside it"
  (start!)
  (test-user:press! "C-x 4 4")
  (check-equal? "C-x 4 4" (description))
  (test-user:press! "C-x b")
  (check (minibuffer:buffer? (views:buffer (layout:selected-view))))
  (test-user:type! "elsewhere")
  (completion-test/picking:choices)
  (test-user:press! "RET")
  (check-equal? '(("notes" #f) ("elsewhere" #t)) (shown))
  (check-equal? #f (description))
  (test-user:press! "C-x 0")
  (check-equal? '(("notes" #t)) (shown)))

(test "a C-u typed after C-x 4 4 is spent by the next command, which opens its file in another view"
  (start!)
  (test-user:press! "C-x 4 4 C-u")
  (check-equal? "C-x 4 4 C-u" (description))
  (test-user:press! "C-x C-f")
  (test-user:press! "C-a C-k")
  (test-user:type! "~/notes/a.txt")
  (completion-test/picking:press-until-ended! "RET" file-picker:find-file)
  (check-equal? '(("notes" #f) ("a.txt" #t)) (shown))
  (test-user:press! "C-x 0"))

(test "input that is no key, such as a paste, leaves C-x 4 4 waiting, and so does a click whose command shows nothing"
  (start!)
  (test-user:press! "C-x 4 4")
  (views:call-with-view (layout:selected-view)
    (lambda () (keys:run-as-input (test-user:client) editing:forward-char)))
  (test-user:settle)
  (test-user:click! (layout:selected-view) 2)
  (check-equal? "C-x 4 4" (description))
  (switch-by-name! "elsewhere")
  (check-equal? '(("notes" #f) ("elsewhere" #t)) (shown))
  (test-user:press! "C-x 0"))

(test "bound elsewhere the prefix is described by its own keys; run by M-x, by its name in brackets, before the keys in progress"
  (start!)
  (keys:bind! keys:global "C-c 4" layout:other-view-prefix)
  (test-user:press! "C-c 4")
  (check-equal? "C-c 4" (description))
  (test-user:press! "C-g")
  (keys:unbind! keys:global "C-c 4")
  (test-user:press! "M-x")
  (test-user:type! "layout:other-view-prefix")
  (completion-test/picking:choices)
  (test-user:press! "RET")
  (check-equal? "[layout:other-view-prefix]" (description))
  (test-user:press! "C-x")
  (check-equal? (list "[layout:other-view-prefix]" "C-x") (list (description) (keys:pending (test-user:client))))
  (check-equal? '("C-x C-g is undefined") (map condition-message (test-runner:reports-during (lambda () (test-user:press! "C-g")))))
  (test-user:press! "C-g")
  (check-equal? #f (description)))

(test "another client's command does not take the wrapper"
  (start!)
  (let ([other (test-user:open-client)])
    (test-user:press! "C-x 4 4")
    (test-user:press! other "C-x o")
    (check-equal? "C-x 4 4" (description))
    (test-user:press! "C-g")
    (web:close-client! other)))

(test "C-M-L run in the other view leaves recenter as the last command, so run again it goes on through recenter's cycle there"
  (start!)
  (layout-split:split-view! (layout:selected-view) (layout-split:direction column))
  (test-user:press! "C-M-L")
  (check (eq? views:recenter-top-bottom (commands:last-command)))
  (test-user:press! "C-x 1"))

(test "the other-view commands' keys"
  (check-equal? (list layout:scroll-other-view layout:scroll-other-view layout:scroll-other-view-down layout:scroll-other-view-down
                      layout:recenter-other-view layout:other-view-backward layout:kill-buffer-and-view)
                (map (lambda (key) (keys:lookup (test-user:client) key)) '("C-M-v" "M-<next>" "C-M-V" "M-<prior>" "C-M-L" "C-x O" "C-x 4 0"))))
