(import (tuna) (test) (owned))

(define drops 0)
(define numbers (owned:make 'owned-test-numbers (lambda () (set! drops (+ drops 1)))))

(define (values-of key) (map owned:entry-value (owned:key-entries numbers key)))

(test "owned:make gives the same set for a name, keeping the newest on-drop"
  (check (owned:set? numbers))
  (check (not (owned:set? 'numbers)))
  (check-equal? numbers (owned:make 'owned-test-numbers (lambda () (set! drops (+ drops 1))))))

(test "each owner has one entry per key, keys compare with equal?, and entries are listed lowest-ranked first"
  (let* ([low (make-owner '(owned low))] [high (make-owner '(owned high))])
    (call-as-owner low (lambda () (owned:add! numbers "one" 1) (owned:add! numbers "one" 11)))
    (call-as-owner high (lambda () (owned:add! numbers (string-copy "one") 2)))
    (check-equal? '(11 2) (values-of "one"))
    (let ([entry (car (owned:key-entries numbers "one"))])
      (check (owned:entry? entry))
      (check-equal? low (owned:entry-owner entry))
      (check-equal? "one" (owned:entry-key entry)))
    (unload-owner! high)
    (unload-owner! low)))

(test "an unload drops the owner's entries and calls on-drop; an unloading owner's entries count for nothing"
  (let ([o (make-owner '(owned dropped))] [seen #f])
    (call-as-owner o
      (lambda ()
        (owned:add! numbers 'k 1)
        (on-unload (lambda () (set! seen (values-of 'k))))))
    (set! drops 0)
    (unload-owner! o)
    (check-equal? '() seen)
    (check-equal? '() (values-of 'k))
    (check-equal? 1 drops)))

(test "a removal hides the entries of owners ranked below it, made before or after, until its owner unloads"
  (let* ([low (make-owner '(owned removal low))] [mid (make-owner '(owned removal mid))] [high (make-owner '(owned removal high))])
    (call-as-owner low (lambda () (owned:add! numbers 'r 'low)))
    (call-as-owner high (lambda () (owned:add! numbers 'r 'high)))
    (call-as-owner mid (lambda () (owned:remove! numbers 'r)))
    (check-equal? '(high) (values-of 'r))
    (call-as-owner low (lambda () (owned:add! numbers 'r 'low-again)))
    (check-equal? '(high) (values-of 'r))
    (unload-owner! mid)
    (check-equal? '(low-again high) (values-of 'r))
    (unload-owner! high)
    (unload-owner! low)))

(test "owned:withdraw! takes back the owner's entry or removal, hiding nothing"
  (let* ([low (make-owner '(owned withdraw low))] [high (make-owner '(owned withdraw high))])
    (call-as-owner low (lambda () (owned:add! numbers 'w 1)))
    (call-as-owner high (lambda () (owned:remove! numbers 'w)))
    (check-equal? '() (values-of 'w))
    (call-as-owner high (lambda () (owned:withdraw! numbers 'w)))
    (check-equal? '(1) (values-of 'w))
    (unload-owner! high)
    (unload-owner! low)))

(test "owned:entries lists every entry in effect, by owner rank, then each owner's order"
  (let* ([low (make-owner '(owned all low))] [high (make-owner '(owned all high))] [set (owned:make 'owned-test-all void)])
    (call-as-owner high (lambda () (owned:add! set 'a 'high-a)))
    (call-as-owner low (lambda () (owned:add! set 'b 'low-b) (owned:add! set 'c 'low-c)))
    (check-equal? '(low-b low-c high-a) (map owned:entry-value (owned:entries set)))
    (unload-owner! high)
    (unload-owner! low)))

(test "a removal of a key compared by eq? is held weakly"
  (let ([o (make-owner '(owned weak))] [probe (weak-cons #f #f)])
    (call-as-owner o
      (lambda ()
        (let ([key (let ([n (random 10)]) (lambda () n))])
          (set-car! probe key)
          (owned:remove! numbers key))))
    (collect (collect-maximum-generation))
    (check (bwp-object? (car probe)))
    (unload-owner! o)))

(test "sets change only on the main thread, as a live owner that is not the kernel"
  (let ([o (make-owner '(owned threaded))])
    (check-raises assertion-violation?
      (let ([raised #f])
        (join-task (fork-task (lambda (restore) (guard (c [#t (set! raised c)]) (call-as-owner o (lambda () (owned:add! numbers 't 1)))))))
        (raise raised)))
    (unload-owner! o)
    (check-raises unloaded? (call-as-owner o (lambda () (owned:add! numbers 't 1))))))
