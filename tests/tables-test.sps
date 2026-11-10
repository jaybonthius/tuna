(import (chezscheme) (tuna test) (tuna core changes) (tuna core modules)
        (except (tuna core main-thread) exit) (tuna tables))

(define (raised-message thunk)
  (guard (c [#t (if (message-condition? c) (condition-message c) c)]) (thunk) #f))

(define (in-thread thunk)
  (let ([result #f])
    (thread-join (fork-thread (lambda () (set! result (thunk)))))
    result))

(define-table keymap)

(define (tests)
  ;; Adding keys grows the table's hashtable while other threads look keys
  ;; up in it.
  (test "other threads read a table while the main thread adds keys"
    (table-set! keymap 'first 1)
    (let ([stop? #f] [bad 0] [reads 0] [mutex (make-mutex)])
      (define (reader)
        (fork-thread
          (lambda ()
            (let loop ([n 0] [wrong 0] [last 0])
              (if stop?
                  (with-mutex mutex (set! bad (+ bad wrong)) (set! reads (+ reads n)))
                  (let ([entries (length (table-entries keymap))])
                    (loop (+ n 1)
                          (if (and (eqv? 1 (table-ref keymap 'first)) (>= entries last)) wrong (+ wrong 1))
                          entries)))))))
      (let ([readers (list (reader) (reader) (reader))])
        (do ([i 0 (+ i 1)]) ((= i 20000))
          (table-set! keymap i (- i)))
        (set! stop? #t)
        (for-each thread-join readers))
      (check-equal? 0 bad)
      (check (> reads 0))
      (check-equal? -19999 (in-thread (lambda () (table-ref keymap 19999))))
      (take-back-changes! '(repl) '())
      (check-equal? '() (table-entries keymap))))

  (test "only the main thread changes tables"
    (for-each
      (lambda (thunk) (check-equal? "only the main thread makes changes" (in-thread (lambda () (raised-message thunk)))))
      (list (lambda () (table-set! keymap 'k 1))
            (lambda () (table-remove! keymap 'k))
            (lambda () (define-table elsewhere) elsewhere)))
    (check-equal? '() (table-entries keymap))
    (check-equal? '() (module-changes '(repl))))

  (test "a quit never leaves a table entry half made"
    (let ([changing? #f] [quits-while-changing 0])
      (define (burn n) (if (fx= n 0) 0 (fx+ 1 (burn (fx- n 1)))))
      (do ([i 0 (+ i 1)]) ((= i 3000))
        (guard (c [(quit-condition? c)
                   (when changing? (set! quits-while-changing (+ quits-while-changing 1)))])
          (burn (random 1500))
          (request-quit!)
          (set! changing? #t)
          (do ([j 0 (fx+ j 1)]) ((fx= j 10))
            (table-set! keymap j j)
            (as-module '(init) (table-set! keymap j (- j)))
            (table-remove! keymap j))
          (set! changing? #f)
          (let loop () (loop))))
      (check (> quits-while-changing 500))
      (for-each (lambda (owner) (take-back-changes! owner '())) '((repl) (init)))
      (check-equal? '() (table-entries keymap))
      (check-equal? '() (module-changes '(repl)))
      (check-equal? '() (module-changes '(init))))))

(post! (lambda ()
         (tests)
         (test-exit)))
(run-main-loop)
