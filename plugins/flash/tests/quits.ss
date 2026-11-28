(import (tuna) (test) (test-user) (test-runner) (views) (buffers) (keys) (tables) (commands) (editing) (echo-area) (web)
        (jump-history) (flash) (flash-test))

(define start "foo fob for\nbar |foo\nfox\nFoo\n")

(define (places) (jump-history:places))

(define (no-marks?)
  (and (null? (flash-test:with-attribute "data-flash-label"))
       (not (exists (lambda (f) (member (car f) '("match.other" "flash.backdrop"))) (flash-test:faced)))
       (not (flash-test:prompt))))

(define outcome #f)
(define reader #f)

(commands:define-command (read-and-keep)
  "Reads a match and keeps what came of it."
  (set! outcome 'waiting)
  (set! reader (current-task))
  (set! outcome (guard (c [(cancelled? c) 'cancelled]) (flash:read-match))))

(keys:bind! keys:global "C-c r" read-and-keep)

(test "C-g and ESC end a jump where it started, its marks gone from the screen drawn after them, say Quit, record nothing, and quit the command"
  (for-each
    (lambda (quit)
      (flash-test:show! start)
      (let ([before (places)])
        (flash-test:press! "C-c ; f o")
        (check (flash-test:quitting! quit))
        (check (no-marks?))
        (check-equal? (list start "Quit" before) (list (flash-test:text) (echo-area:current-message) (places)))))
    '("C-g" "ESC"))
  (flash-test:press! "C-c r f o C-g")
  (check-equal? 'cancelled outcome))

(test "a jump shows on the client that started it only; another client's keys run as usual"
  (let ([other (flash-test:open-user)])
    (flash-test:show! start)
    (flash-test:press! "C-c ; f o")
    (check-equal? '("foo fob for" "bar foo" "fox" "Foo" "") (flash-test:lines other (flash-test:view)))
    (check-equal? '() (filter (lambda (f) (member (car f) '("match.other" "flash.backdrop"))) (flash-test:faced other (flash-test:view))))
    (check-equal? #f (flash-test:prompt other))
    (flash-test:press! other "C-e")
    (check-equal? "foo fob for\nbar foo|\nfox\nFoo\n" (flash-test:text))
    (check-equal? "Flash [fo] (6): " (flash-test:prompt))
    (check (flash-test:quitting! "C-g"))
    (web:close-client! other)))

(test "a jump ends when its client is removed: its marks go, and the read raises &cancelled"
  (let ([c (flash-test:open-user)] [sources (length (tables:entries views:span-sources))])
    (flash-test:show! start)
    (flash-test:press! c "C-c r f o")
    (check-equal? (+ sources 3) (length (tables:entries views:span-sources)))
    (web:close-client! c)
    (test-runner:wait-until (lambda () (not (eq? outcome 'waiting))))
    (check-equal? 'cancelled outcome)
    (check-equal? sources (length (tables:entries views:span-sources)))))

(test "a key that reaches Tuna in one batch with the label before it acts after the jump has moved point"
  (flash-test:show! start)
  (flash-test:press! "C-c ; f o")
  (test-user:press-together! (flash-test:user) "a C-e")
  (test-runner:wait-until (lambda () (equal? "foo fob for\nbar foo\nfox|\nFoo\n" (flash-test:text))))
  (check (no-marks?)))

(test "a quit that reaches Tuna in one batch with characters before it quits the jump after they joined the pattern"
  (flash-test:show! start)
  (flash-test:press! "C-c ; f")
  (let ([reports (test-runner:reports-during
                   (lambda ()
                     (test-user:press-together! (flash-test:user) "o x C-g")
                     (test-runner:wait-until (lambda () (not (flash-test:prompt)))))
                   1)])
    (check (for-all cancelled? reports)))
  (check-equal? (list start "Quit") (list (flash-test:text) (echo-area:current-message))))

(test "a jump whose task is stopped ends: no mark, keymap or source of it remains"
  (let ([sources (length (tables:entries views:span-sources))])
    (flash-test:show! start)
    (flash-test:press! "C-c r f o")
    (stop-task reader)
    (test-runner:wait-until (lambda () (eq? 'done (task-state reader))))
    (test-user:settle)
    (check (no-marks?))
    (check-equal? sources (length (tables:entries views:span-sources)))
    (flash-test:press! "C-c ; f o")
    (check-equal? "Flash [fo] (6): " (flash-test:prompt))
    (check (flash-test:quitting! "C-g"))))
