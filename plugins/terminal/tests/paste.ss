(import (tuna) (test) (test-runner) (test-user) (options) (ask) (buffers) (views) (keys) (web) (editing) (kill-ring)
        (terminal) (terminal-test))

(define told '())

(options:set! ask:message-writer (lambda (text) (set! told (cons text told))))

(define client (test-user:client))

(define (paste! text) (web:post-input! client (list (cons "type" "paste") (cons "text" text))) (test-user:settle))

(define (copies) (filter (lambda (call) (equal? "copy" (car call))) (test-user:take-page-calls!)))

(define (remapping command) (terminal-test:in-view (lambda () (keys:command-remapping client command))))

(test "the browser's paste sends the text as libghostty encodes a paste: line breaks as carriage returns, or bracketed when the program asked"
  (check-equal? "61 62 0d 63 64" (terminal-test:bytes-read (list (lambda () (paste! "ab\ncd"))) 5))
  (check-equal? "1b 5b 32 30 30 7e 61 62 0a 63 64 1b 5b 32 30 31 7e"
                (terminal-test:bytes-read (list (lambda () (paste! "ab\ncd"))) 17 "printf '\\033[?2004h'; ")))

(test "C-y and C-c C-y send the kill ring's current entry the same way"
  (kill-ring:push! (list "k1"))
  (check-equal? "6b 31 6b 31" (terminal-test:bytes-read '("C-y" "C-c C-y") 4)))

(define t (terminal-test:shell!))

(test "a terminal remaps paste, yank and the middle button's yank, and nothing else of editing's"
  (terminal-test:show! t)
  (check (eq? terminal:paste (remapping editing:paste)))
  (check (eq? terminal:yank (remapping editing:yank)))
  (check (eq? terminal:mouse-yank-primary (remapping editing:mouse-yank-primary)))
  (check-equal? #f (remapping editing:kill-line)))

(test "a program's copy goes on the kill ring and to the clipboard of the device whose input reached the terminal last"
  (test-user:press! "SPC DEL")
  (copies)
  (terminal:send! t "printf '\\e]52;c;aGVsbG8=\\a'\r")
  (test-runner:wait-until (lambda () (equal? "hello" (kill-ring:text (kill-ring:current)))))
  (check-equal? '(("copy" . "hello")) (copies)))

(test "with program-copy? off a program's copy goes nowhere"
  (options:set! terminal:program-copy? #f)
  (terminal:send! t "printf '\\e]52;c;Ynll\\a'; echo sent\r")
  (terminal-test:wait-for t "\nsent")
  (check-equal? "hello" (kill-ring:text (kill-ring:current)))
  (check-equal? '() (copies))
  (options:unset! terminal:program-copy?))

(test "a program can never read the clipboard: its query gets an empty answer"
  (check-equal? "1b 5d 35 32 3b 63 3b 07" (terminal-test:bytes-read '() 8 "printf '\\033]52;c;?\\007'; ")))

(test "the middle button sends the primary selection, the last region active when a command ended"
  (terminal-test:show! (buffers:make "notes" "primary text"))
  (test-user:press! "C-SPC C-f C-f C-f")
  (check-equal? '("Mark set") told)
  (check-equal? "70 72 69"
    (terminal-test:bytes-read
      (list (lambda ()
              (test-user:click! (terminal-test:view) (terminal-test:position-of (views:buffer (terminal-test:view)) "ready")
                                "<mouse-2>")))
      3)))
