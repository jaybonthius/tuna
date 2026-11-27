(import (tuna) (test) (test-runner) (jobs) (jobs-test))

(define (raised? who message irritants)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (message-condition? c) (string=? message (condition-message c))
         (equal? irritants (condition-irritants c)))))

(define (ignore v) (void))

(jobs:define-worker (match-names query emit)
  (emit (string-append "matches for " query))
  (emit (list 1 2 (vector 3))))

(jobs:define-worker (count-up n emit) (do ([i 0 (+ i 1)]) ((= i n)) (emit i)))

(test "a worker is a value of its own"
  (check-equal? '(#t #f) (list (jobs:worker? match-names) (jobs:worker? car)))
  (check-equal? "#<worker match-names>" (format "~s" match-names)))

(test "each value a job emits reaches on-result in order, then on-end gets #f when the body returned"
  (check-equal? '(("matches for spe" (1 2 #(3))) #f) (jobs-test:finished match-names "spe"))
  (check-equal? (list (iota 1000) #f) (jobs-test:finished count-up 1000)))

(test "on-result and on-end run as tasks on the main thread, as the owner that started the job"
  (let* ([notes '()] [note! (lambda (x) (set! notes (cons x notes)))]
         [job (jobs:start match-names "x"
                (lambda (v) (note! (list (current-owner) (task? (current-task)))))
                (lambda (ended) (note! (list 'ended ended (current-owner)))))])
    (check-equal? '(#t #f) (list (jobs:job? job) (jobs:job? match-names)))
    (check-equal? "#<job match-names>" (format "~s" job))
    (test-runner:wait-until (lambda () (= (length notes) 3)))
    (let ([me (current-owner)])
      (check-equal? (list (list me #t) (list me #t) (list 'ended #f me)) (reverse notes)))))

(jobs:define-worker (word-count text emit)
  (import (jobs-test words))
  (emit (word-count text)))

(define (job-values worker input)
  (let ([results '()])
    (define (add! v) (set! results (cons v results)))
    (define (result ended)
      (if (condition? ended) (raise ended) (reverse results)))
    (suspend
      (lambda (resume)
        (jobs:start worker input add!
          (lambda (ended) (resume (lambda () (result ended)))))))))

(test "a worker imports a library, and a task pauses for a job's values"
  (check-equal? '((4) #f) (jobs-test:finished word-count "to be or not"))
  (check-equal? '(0 1 2 3 4) (job-values count-up 5)))

(define secret 42)

(jobs:define-worker (sees-top-level x emit) (emit secret))

(jobs:define-worker (greets x emit) (import (jobs-test greeter)) (emit (jobs-test/greeter:greeting)))

(jobs:define-worker (greets-through x emit) (import (jobs-test wraps)) (emit (wrapped-greeting)))

(test "a body sees Chez's names and its imports only, and no library that uses Tuna, which jobs:start reports by raising"
  (check-raises (lambda (c) (and (syntax-violation? c) (string=? "attempt to reference unbound identifier" (condition-message c))))
    (jobs:start sees-top-level 1 void))
  (check-raises (raised? 'greets "a worker cannot import a library that uses Tuna" '((jobs-test greeter)))
    (jobs:start greets 1 void))
  (check-raises (raised? 'greets-through "a worker cannot import a library that uses Tuna" '((jobs-test wraps)))
    (jobs:start greets-through 1 void)))

(jobs:define-worker (fails x emit) (emit 'before) (car x))

(jobs:define-worker (warns x emit) (warning 'warns "careful") (emit 'went-on))

(test "a raise ends the job: it is reported, then on-end receives it"
  (let* ([ended #f]
         [reported (test-runner:reports-during (lambda () (set! ended (jobs-test:finished fails 1))) 1)])
    (check-equal? 1 (length reported))
    (check-equal? '(before) (car ended))
    (check (eq? (car reported) (cadr ended)))
    (check-equal? "~s is not a pair" (condition-message (cadr ended)))))

(test "a warning is reported and the body goes on"
  (let* ([ended #f]
         [reported (test-runner:reports-during (lambda () (set! ended (jobs-test:finished warns 1))) 1)])
    (check-equal? 1 (length reported))
    (check (warning? (car reported)))
    (check-equal? '((went-on) #f) ended)))

(jobs:define-worker (raises x emit) (raise x))

(jobs:define-worker (warns-raising x emit) (raise (make-warning)) (emit 'went-on))

(test "a raised value that looks like an ending is still a raise"
  (let* ([ended '()]
         [reported (test-runner:reports-during
                     (lambda ()
                       (set! ended (list (jobs-test:finished raises #f) (jobs-test:finished raises 'stopped))))
                     2)])
    (check-equal? '(#f stopped) reported)
    (check-equal? '((() #f) (() stopped)) ended)))

(test "a warning raised with raise cannot go on, so the job ends with the non-continuable violation that follows"
  (let* ([ended #f]
         [reported (test-runner:reports-during (lambda () (set! ended (jobs-test:finished warns-raising 1))) 2)])
    (check-equal? 2 (length reported))
    (check (warning? (car reported)))
    (check (non-continuable-violation? (cadr reported)))
    (check-equal? '() (car ended))
    (check (non-continuable-violation? (cadr ended)))))

(jobs:define-worker (leaks x emit) (emit (lambda () x)))

(test "emit takes only plain data"
  (let* ([ended #f]
         [reported (test-runner:reports-during (lambda () (set! ended (jobs-test:finished leaks 1))) 1)])
    (check-equal? '() (car ended))
    (check ((raised? 'emit "not plain data" (condition-irritants (car reported))) (car reported)))
    (check (procedure? (car (condition-irritants (car reported)))))))

(jobs:define-worker (quits how emit)
  (emit 'before)
  (case how [(exit) (exit 3)] [(reset) (reset)] [(abort) (abort)])
  (emit 'after))

(test "Chez's exit, reset and abort end only the job"
  (check-equal? '(((before) #f) ((before) #f) ((before) #f))
    (map (lambda (how) (jobs-test:finished quits how)) '(exit reset abort))))

(jobs:define-worker (waits-badly x emit receive) (receive -1))

(test "arguments are checked, and values where they cross: in jobs:start, jobs:send! and emit"
  (check-raises (raised? 'jobs:start "not plain data" (list car)) (jobs:start match-names car void))
  (check-raises (raised? 'jobs:start "not a worker" (list void)) (jobs:start void "x" void))
  (check-raises (raised? 'jobs:start "not a procedure" '(note!)) (jobs:start match-names "x" 'note!))
  (check-raises (raised? 'jobs:start "not a procedure" '(ended)) (jobs:start match-names "x" void 'ended))
  (let ([job (jobs:start count-up 1 ignore)])
    (check-raises (lambda (c) (and (assertion-violation? c) (string=? "not plain data" (condition-message c))))
      (jobs:send! job (make-eq-hashtable))))
  (check-raises (raised? 'jobs:send! "not a job" '(parsing)) (jobs:send! 'parsing 1))
  (check-raises (raised? 'jobs:stop! "not a job" (list match-names)) (jobs:stop! match-names))
  (let* ([ended #f]
         [reported (test-runner:reports-during (lambda () (set! ended (jobs-test:finished waits-badly 0))) 1)])
    (check-equal? '() (car ended))
    (check ((raised? 'receive "not a number of seconds" '(-1)) (cadr ended)))))

(test "jobs:start raises on another thread"
  (let ([message #f])
    (join-task (fork-task (lambda (restore) (set! message (guard (c [(assertion-violation? c) (condition-message c)]) (jobs:start match-names "x" void))))))
    (check-equal? "not on the main thread" message)))

(jobs:define-worker (sizes v emit) (emit (map vector-length v)))

(test "a frozen vector is checked once, and values holding it pass as plain data"
  (let ([words (jobs:freeze (vector "to" "be" (list "or" "not")))])
    (check (immutable-vector? words))
    (check-equal? '#("to" "be" ("or" "not")) words)
    (check (eq? words (jobs:freeze words)))
    (check-equal? '(((3 3)) #f) (jobs-test:finished sizes (list words words))))
  (check-raises (raised? 'jobs:freeze "not a vector" '(("to" "be"))) (jobs:freeze '("to" "be")))
  (check-raises (raised? 'jobs:freeze "not plain data" (list (vector "to" car))) (jobs:freeze (vector "to" car))))

(test "an immutable vector jobs:freeze did not make is walked, and a cycle through it is found"
  (let ([words (jobs:freeze (vector "to" "be" (list "or" "not")))])
    (check-equal? '(((3 2)) #f) (jobs-test:finished sizes (list words (vector->immutable-vector (vector "or" words)))))
    (check-raises (lambda (c) (and (assertion-violation? c) (string=? "not plain data" (condition-message c))))
      (jobs:freeze (vector words (vector->immutable-vector (vector car)))))
    (let ([looped (vector words)])
      (vector-set! looped 0 (vector->immutable-vector (vector words looped)))
      (let ([job (jobs:start sizes (list words) ignore)])
        (check-raises (lambda (c) (and (assertion-violation? c) (string=? "not plain data" (condition-message c))))
          (jobs:send! job (vector looped)))))))

(test "each name the plugin offers is a changeable definition, so it can be advised"
  (let* ([starts 0]
         [counting-starts (lambda (start . arguments) (set! starts (+ starts 1)) (apply start arguments))])
    (advice-add! jobs:start counting-starts)
    (check-equal? '(("matches for a" (1 2 #(3))) #f) (jobs-test:finished match-names "a"))
    (advice-remove! jobs:start counting-starts)
    (check-equal? '(("matches for b" (1 2 #(3))) #f) (jobs-test:finished match-names "b"))
    (check-equal? 1 starts)))
