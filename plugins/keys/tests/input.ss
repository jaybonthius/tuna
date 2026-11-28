(import (tuna) (test) (test-runner) (test-user) (web) (tables) (timers) (commands) (keys) (keys-test))

(define seen '())

(define (see! . what) (set! seen (cons what seen)))

(define (take-seen!) (let ([s (reverse seen)]) (set! seen '()) s))

(commands:define-command (insert-text text)
  "Records TEXT and what the command sees of its run."
  (see! text (keys:command-keys) (keys:typed-char) (commands:prefix-argument) (eq? (web:current-client) (test-user:client))
        (eq? (commands:this-command) insert-text)))

(commands:define-command (replaced-insert text)
  "Records TEXT as replaced."
  (see! 'replaced text))

(commands:define-command (visit)
  "Records its prefix argument."
  (see! 'visit (commands:prefix-argument)))

(commands:define-command (run-input)
  "Runs insert-text as input."
  (keys:run-as-input (test-user:client) insert-text "e"))

(commands:define-command (wait)
  "Waits until resumed or quit."
  (see! 'waiting)
  (guard (c [(cancelled? c) (see! 'quit)])
    (suspend (lambda (resume) #f))))

(keys:bind! keys:global "C-x C-f" visit)
(keys:bind! keys:global "C-c i" run-input)

(test "input that is no key runs its command with the client current, as a command no key ran, with no prefix argument"
  (keys:run-as-input (test-user:client) insert-text "hi")
  (check-equal? '(("hi" #f #f #f #t #t)) (take-seen!))
  (check (eq? insert-text (commands:last-command)))
  (check-equal? #f (web:current-client)))

(test "it leaves a prefix argument and its keymap for the next key"
  (test-user:press! "C-u")
  (keys:run-as-input (test-user:client) insert-text "a")
  (check-equal? '(("a" #f #f #f #t #t)) (take-seen!))
  (check-equal? "C-u" (keys:prefix-description (test-user:client)))
  (test-user:press! "5 C-x C-f")
  (check-equal? '((visit 5)) (take-seen!)))

(test "it leaves a sequence in progress pending, and the next key ends it"
  (test-user:press! "C-x")
  (keys:run-as-input (test-user:client) insert-text "b")
  (check-equal? '(("b" #f #f #f #t #t)) (take-seen!))
  (check-equal? "C-x" (keys:pending (test-user:client)))
  (test-user:press! "C-f")
  (check-equal? '((visit #f)) (take-seen!)))

(test "a temporary keymap stays, unasked, and its remapping applies"
  (tables:define-table replacing-keymap "replacing")
  (let* ([asked 0]
         [end (keys:push-keymap! (test-user:client) replacing-keymap (lambda (found command) (set! asked (+ asked 1)) #t))])
    (keys:remap! replacing-keymap insert-text replaced-insert)
    (check-equal? replaced-insert (keys:command-remapping (test-user:client) insert-text))
    (keys:run-as-input (test-user:client) insert-text "c")
    (check-equal? '((replaced "c")) (take-seen!))
    (check-equal? 0 asked)
    (check (memq replacing-keymap (keys:active-keymaps (test-user:client))))
    (end)
    (keys:run-as-input (test-user:client) insert-text "d")
    (check-equal? '(("d" #f #f #f #t #t)) (take-seen!))))

(test "run inside a key's command, it still runs as no key"
  (test-user:press! "C-u C-c i")
  (check-equal? '(("e" #f #f #f #t #t)) (take-seen!)))

(test "C-g quits a command run as input that waits, as it quits a key's"
  (let ([as-input (spawn-task (lambda (restore) (keys:run-as-input (test-user:client) wait)))])
    (test-user:settle)
    (check-equal? '((waiting)) (take-seen!))
    (keys:press! (test-user:client) "C-g")
    (test-runner:join as-input)
    (check-equal? '((quit)) (take-seen!))))

(test "run-as-input takes a client and a command on the main thread"
  (check-raises (test-runner:raised-with 'keys:run-as-input "not a command") (keys:run-as-input (test-user:client) 'insert-text "f"))
  (check-raises (test-runner:raised-with 'keys:run-as-input "not a client") (keys:run-as-input 'one insert-text "f"))
  (check-equal? '(keys:run-as-input "not on the main thread")
                (keys-test:on-thread (lambda () (keys:run-as-input (test-user:client) insert-text "g")))))

(define idle-runs 0)

(define typed 0)

(commands:define-command (type-one) "Counts a character typed." (set! typed (+ typed 1)))

(keys:bind! keys:global "C-c 2" type-one)

;; The claims are that an idle timer does not run again until input ends
;; idleness, so each check waits past the timer's delay and counts.
(define (after-idle-delay) (timers:sleep 0.2))

(test "input that is no item, from a timer, ends idleness, so an idle timer runs again; commands run one after another start none"
  (let ([idle-timer (timers:run-when-idle 0.1 (lambda () (set! idle-runs (+ idle-runs 1))))])
    (timers:set-idle! #t)
    (test-runner:wait-until (lambda () (= idle-runs 1)))
    (after-idle-delay)
    (check-equal? 1 idle-runs)
    (timers:run-after 0 (lambda () (for-each (lambda (i) (keys:run-as-input (test-user:client) type-one)) (iota 40))))
    (test-runner:wait-until (lambda () (= idle-runs 2)))
    (after-idle-delay)
    (check-equal? '(40 2) (list typed idle-runs))
    (timers:run-after 0 (lambda () (keys:press! (test-user:client) "C-c") (keys:press! (test-user:client) "2")))
    (test-runner:wait-until (lambda () (= idle-runs 3)))
    (after-idle-delay)
    (check-equal? '(41 3) (list typed idle-runs))
    (timers:cancel! idle-timer)))

(define idleness '())

(commands:define-command (wait-briefly)
  "Notes idleness before and after a pause."
  (set! idleness (cons (timers:idle-seconds) idleness))
  (timers:sleep 0.2)
  (set! idleness (cons (timers:idle-seconds) idleness)))

(test "Tuna is busy while a command run as input runs and idle while it waits"
  (let ()
    (timers:set-idle! #t)
    (let ([t (spawn-task (lambda (restore) (keys:run-as-input (test-user:client) wait-briefly)))])
      (test-runner:wait-until (lambda () (pair? idleness)))
      (check (real? (timers:idle-seconds)))
      (test-runner:join t)
      (check-equal? '(#f #f) idleness)
      (check (real? (timers:idle-seconds))))))

(test "input while Tuna is busy, as inside an item, leaves idleness alone"
  (timers:set-idle! #f)
  (set! typed 0)
  (keys:run-as-input (test-user:client) type-one)
  (keys:press! (test-user:client) "C-c")
  (keys:press! (test-user:client) "2")
  (check-equal? '(2 #f) (list typed (timers:idle-seconds))))
