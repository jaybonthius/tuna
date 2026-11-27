(import (tuna) (test) (test-runner) (web) (haml) (hooks) (timers) (web-test http))

(web-test/http:use-url! (lambda () (web:url)))
(test-runner:wait-until (lambda () (web:url)))

(define added '())
(define removed '())

(define (note-added client) (set! added (append added (list client))))
(define (note-removed client) (set! removed (append removed (list client))))

(hooks:add! web:client-added note-added)
(hooks:add! web:client-removed note-removed)

(define (removed!) (let ([r removed]) (set! removed '()) r))

;; Each removal an hour away is a timer of web's.
(define (removals) (length (timers:live)))

(define (remove-now!)
  (for-each (lambda (timer) (timers:cancel! timer) ((timers:procedure timer))) (timers:live)))

;; Tuna learns that a stream has closed when it next writes to it.
(define (written-until done?)
  (test-runner:wait-until
    (lambda ()
      (for-each (lambda (client) (web:call-page! client "ping" 0)) (web:clients))
      (done?))))

(define a (web-test/http:page))
(define b (web-test/http:page))
(define c (web-test/http:page))
(test-runner:wait-until (lambda () (= 3 (length added))))

(define (client-of page) (cdr (assq page (map cons (list a b c) added))))

(test "serving the page adds a client, whose id is 128 random bits"
  (check (for-all web:client? added))
  (check-equal? 32 (string-length (web-test/http:id a)))
  (check (not (string=? (web-test/http:id a) (web-test/http:id b))))
  (check-equal? '(#f #f) (list (web:client? 'a) (web:client? a))))

(test "a client whose stream never opens is to be removed an hour after its page was served"
  (test-runner:wait-until (lambda () (= 3 (removals)))))

(test "web:clients gives the connected clients in the order they were added, and opening its stream cancels a client's removal"
  (web-test/http:connect! c)
  (web-test/http:connect! a)
  (check-equal? (list (client-of a) (client-of c)) (web:clients))
  (test-runner:wait-until (lambda () (= 1 (removals))))
  (remove-now!)
  (check-equal? (list (client-of b)) (removed!)))

(test "a second stream for a client, as when a hidden tab shows again before its first stream closed, replaces the first"
  (web-test/http:connect! a)
  (check-equal? (list (client-of a) (client-of c)) (web:clients)))

(test "an idle stream gets a comment every 15 seconds, even while another client's stream is busy"
  (let ([seen (web-test/http:heartbeats c)])
    (let loop ([n 0])
      (cond
        [(> (web-test/http:heartbeats c) seen)
         (check-equal? n (length (web-test/http:take a n)))]
        [(= n 40) (check (> (web-test/http:heartbeats c) seen))]
        [else
         (web:call-page! (client-of a) "ping" n)
         (timers:sleep 0.5)
         (loop (+ n 1))])))
  (check-equal? (list (client-of a) (client-of c)) (web:clients)))

(test "a page that unloads says goodbye, which removes its client"
  (check-equal? 204 (web-test/http:goodbye! c))
  (test-runner:wait-until (lambda () (= 1 (length (web:clients)))))
  (check-equal? (list (client-of a)) (web:clients))
  (check-equal? (list (client-of c)) (removed!)))

(test "a removed client's open stream makes its page reload, and so does a stream of a client Tuna does not know"
  (check-equal? '((script "location.reload()") closed) (web-test/http:take c 2))
  (let ([first (web-test/http:connect-and-next! c)])
    (check-equal? '((script "location.reload()") closed) (list first (web-test/http:next c)))))

(test "a client whose stream closes is to be removed an hour later, unless its stream opens again first"
  (web-test/http:close! a)
  (written-until (lambda () (= 1 (removals))))
  (check-equal? '() (web:clients))
  (web-test/http:connect! a)
  (test-runner:wait-until (lambda () (= 0 (removals))))
  (check-equal? (list (client-of a)) (web:clients))
  (web-test/http:close! a)
  (written-until (lambda () (= 1 (removals))))
  (remove-now!)
  (check-equal? (list (client-of a)) (removed!))
  (let ([first (web-test/http:connect-and-next! a)])
    (check-equal? '((script "location.reload()") closed) (list first (web-test/http:next a)))))

(test "a plugin keeps per-client state in an eq hashtable keyed by the client, dropped in client-removed"
  (let* ([names (make-eq-hashtable)]
         [name! (lambda (client) (hashtable-set! names client "a name"))]
         [forget! (lambda (client) (hashtable-delete! names client))])
    (hooks:add! web:client-added name!)
    (hooks:add! web:client-removed forget!)
    (let ([d (web-test/http:page)])
      (web-test/http:connect! d)
      (check-equal? "a name" (hashtable-ref names (car (web:clients)) #f))
      (web-test/http:goodbye! d)
      (test-runner:wait-until (lambda () (zero? (hashtable-size names)))))
    (hooks:remove! web:client-added name!)
    (hooks:remove! web:client-removed forget!)))
