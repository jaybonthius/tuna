(import (tuna) (test) (test-runner) (test-user) (web) (hooks) (options) (tables) (commands) (keys) (keys-test) (keys-test quits)
        (rename (only (chezscheme) sleep) (sleep chez:sleep)))

(define (sleep-ms ms) (chez:sleep (make-time 'time-duration (* ms 1000000) 0)))

(define seen '())

(define (see! . what) (set! seen (cons what seen)))

(define (take-seen!) (let ([s (reverse seen)]) (set! seen '()) s))

(commands:define-command (visit) "Records its prefix argument." (see! 'visit (commands:prefix-argument)))

(commands:define-command (next-line) "Records itself." (see! 'next-line))

(commands:define-command (self-insert) "Records the character typed." (see! 'self-insert (keys:typed-char)))

(commands:define-command (other) "Does nothing." (void))

(tables:define-table repeat-keymap "Keys that go on after repeat-other.")

(commands:define-command (repeat-other)
  "Lets o run other until another key."
  (keys:push-keymap! (web:current-client) repeat-keymap (lambda (found command) (eq? found repeat-keymap))))

(tables:define-table stress-keymap "The keys the storm presses.")

(keys:bind! repeat-keymap "o" other)
(keys:bind! stress-keymap "C-x C-f" visit)
(keys:bind! stress-keymap "C-x o" other)
(keys:bind! stress-keymap "C-c o" repeat-other)
(keys:bind! stress-keymap "C-n" next-line)
(keys:bind! stress-keymap "M-x" next-line)
(keys:bind! stress-keymap "<printing-char>" self-insert)

(define (stress-keymaps client posn) (if posn '() (list stress-keymap)))

(hooks:add! keys:find-keymaps stress-keymaps -50)

(test "only the main thread presses, looks up, pushes, binds and remaps; any thread reads bindings and names items, and runs no command"
  (tables:define-table threads-keymap "threads")
  (keys:bind! threads-keymap "a" other)
  (let ([one (test-user:client)])
    (check-equal? '((keys:press! "not on the main thread") (keys:lookup "not on the main thread")
                    (keys:active-keymaps "not on the main thread") (keys:active-bindings "not on the main thread")
                    (keys:where-is "not on the main thread") (keys:command-remapping "not on the main thread")
                    (keys:pending "not on the main thread") (keys:push-keymap! "not on the main thread")
                    (keys:bind! "not on the main thread") (keys:remap! "not on the main thread")
                    (keys:lookup-in "not on the main thread") (keys:prompt "not on the main thread")
                    (keys:page-quit-keys "not on the main thread")
                    1 (#f #f #f #f) "C-x")
                  (map keys-test:on-thread
                       (list (lambda () (keys:press! one "a"))
                             (lambda () (keys:lookup one "a"))
                             (lambda () (keys:active-keymaps one))
                             (lambda () (keys:active-bindings one))
                             (lambda () (keys:where-is one other))
                             (lambda () (keys:command-remapping one other))
                             (lambda () (keys:pending one))
                             (lambda () (keys:push-keymap! one threads-keymap (lambda (f c) #t)))
                             (lambda () (keys:bind! threads-keymap "b" other))
                             (lambda () (keys:remap! threads-keymap other visit))
                             (lambda () (keys:lookup-in (list threads-keymap) "a"))
                             (lambda () (keys:prompt one))
                             (lambda () (keys:page-quit-keys one))
                             (lambda () (length (keys:bindings threads-keymap)))
                             (lambda () (list (keys:command-keys) (keys:command-event) (keys:typed-char) (keys:shift-translated?)))
                             (lambda () (keys:item-key '(("key" . "x") ("code" . "KeyX") ("modifiers" . #("control"))))))))
    (check-equal? '(owned:remove! "only the main thread makes changes")
                  (keys-test:on-thread (lambda () (keys:unbind! threads-keymap "a"))))
    (let ([end (keys:push-keymap! one threads-keymap (lambda (f c) #t))])
      (check-equal? '(keys:push-keymap! "not on the main thread") (keys-test:on-thread end))
      (end))))

(test "threads naming items while the main thread changes the Option options see one setting or the other, never a mix"
  (let ([option-item '(("key" . "≈") ("code" . "KeyX") ("modifiers" . #("left-option")))]
        [plain-item '(("key" . "X") ("code" . "KeyX") ("modifiers" . #("control" "shift")))]
        [converting (box #t)] [bad '()] [converted 0])
    (let ([converters
           (map (lambda (i)
                  (fork-task
                    (lambda (restore)
                      (let loop ()
                        (when (unbox converting)
                          (let ([a (keys:item-key option-item)] [b (keys:item-key plain-item)])
                            (unless (and (member a '("M-x" "≈")) (equal? b "C-X"))
                              (set! bad (cons (list a b) bad))))
                          (set! converted (+ converted 1))
                          (loop))))))
                '(1 2 3 4))])
      (do ([i 0 (+ i 1)]) ((= i 20000)) (options:set! keys:left-option-meta? (even? i)))
      (set-box! converting #f)
      (for-each test-runner:join converters)
      (options:unset! keys:left-option-meta?)
      (check (> converted 1000))
      (check-equal? '() bad))))

(test "threads reading a keymap's bindings while the main thread binds and unbinds see whole lists"
  (tables:define-table read-keymap "read")
  (let ([reading (box #t)] [bad '()] [reads 0])
    (let ([readers
           (map (lambda (i)
                  (fork-task
                    (lambda (restore)
                      (let loop ()
                        (when (unbox reading)
                          (let ([bs (keys:bindings read-keymap)])
                            (unless (and (list? bs) (for-all (lambda (b) (and (string? (car b)) (procedure? (cdr b)))) bs))
                              (set! bad (cons bs bad))))
                          (set! reads (+ reads 1))
                          (loop))))))
                '(1 2 3 4))])
      (do ([i 0 (+ i 1)]) ((= i 5000))
        (let ([k (format "C-c ~a ~a" (mod i 7) (mod i 9))])
          (if (even? i) (keys:bind! read-keymap k other) (keys:unbind! read-keymap k))))
      (set-box! reading #f)
      (for-each test-runner:join readers)
      (check (> reads 100))
      (check-equal? '() bad))))

;; Pending keys are whole when they are a prefix or end in an ESC that
;; waits to make the next key Meta, which lookup gives #f for.
(define (whole-pending? client p)
  (let ([n (string-length p)])
    (or (and (keys:lookup client p) #t)
        (and (>= n 3) (string=? (substring p (- n 3) n) "ESC")
             (or (= n 3) (char=? (string-ref p (- n 4)) #\space))))))

;; A key pressed in the test's own task raises its warning there, where
;; no command loop reports it.
(define (warning-messages thunk)
  (let ([messages '()])
    (with-exception-handler
      (lambda (c)
        (if (warning? c)
            (set! messages (cons (condition-message c) messages))
            (raise-continuable c)))
      thunk)
    (reverse messages)))

(test "quits landing in presses, lookups, prefix arguments, commands and temporary keymaps leave the client's session whole"
  (let* ([one (test-user:client)] [quitting (box #t)] [quits 0] [quits-reported 0] [warnings 0]
         [presses 0]
         [keys-pressed '("C-u" "C-x" "C-f" "C-c" "o" "o" "C-n" "ESC" "x" "M-5" "1" "C-x" "o" "C-g" "a" "C-x" "ESC" "C-g")]
         [warnings-counted (lambda (thunk)
                             (with-exception-handler
                               (lambda (c) (if (warning? c) (set! warnings (+ warnings 1)) (raise-continuable c)))
                               thunk))]
         [count-reports (lambda (next c)
                          (cond
                            [(cancelled? c) (set! quits-reported (+ quits-reported 1))]
                            [(warning? c) (set! warnings (+ warnings 1))]
                            [else (next c)]))])
    (options:set! keys:quit-keys '("C-g"))
    (keys:unbind! keys:global "ESC")
    (advice-add! report count-reports)
    ;; A quit lands up to a thousand ticks after it is asked for, and one
    ;; asked for just before the quitter stops may land after it has. One
    ;; guard holds from before the quitter starts until well after it has
    ;; stopped, since a quit between two guards would end the test.
    (let ([quitter #f] [until (+ (real-time) 1500)])
      (let again ()
        (guard (c [(cancelled? c) (set! quits (+ quits 1)) (again)])
          (unless quitter
            (set! quitter
              (fork-task
                (lambda (restore)
                  (let loop ()
                    (when (unbox quitting)
                      (keys-test/quits:request-quit!)
                      (sleep-ms 1)
                      (loop)))))))
          (warnings-counted
            (lambda ()
              (let loop ()
                (when (< (real-time) until)
                  (for-each (lambda (k) (keys:press! one k) (set! presses (+ presses 1))) keys-pressed)
                  (loop)))))
          (set-box! quitting #f)
          (test-runner:join quitter)
          (let settle ([n 0]) (when (< n 100000) (settle (+ n 1)))))))
    (advice-remove! report count-reports)
    (check (> (+ quits quits-reported) 100))
    (check (> presses 1000))
    (let ([left (keys:pending one)])
      (check (or (not left) (whole-pending? one left)))
      (check-equal? (if left (list (string-append left " C-g is undefined")) '())
                    (warning-messages (lambda () (keys:press! one "C-g") (keys:press! one "C-g")))))
    (check-equal? '(#f #f) (list (keys:pending one) (keys:prefix-description one)))
    (check (not (memq repeat-keymap (keys:active-keymaps one))))
    (take-seen!)
    (for-each (lambda (k) (keys:press! one k)) '("C-u" "C-x" "C-f" "x" "ESC" "x"))
    (check-equal? '((visit (4)) (self-insert #\x) (next-line)) (take-seen!))
    (options:unset! keys:quit-keys)
    (keys:bind! keys:global "ESC" keys:keyboard-quit)))
