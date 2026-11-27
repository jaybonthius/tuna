(import (tuna) (test) (test-runner) (web) (haml) (tables) (timers) (web-test http)
        (rename (only (chezscheme) sleep) (sleep chez:sleep)))

(web-test/http:use-url! (lambda () (web:url)))
(test-runner:wait-until (lambda () (web:url)))

(define request-quit! (test-runner:running-task-canceller))

(define pages (list (web-test/http:page) (web-test/http:page) (web-test/http:page) (web-test/http:page)))

(define runs (make-eq-hashtable))

(test "four pages each send 300 items from three threads at once, out of order, and each client's items run in the order it numbered them"
  (tables:set! web:input-handlers "flood"
    (lambda (client item)
      (hashtable-update! runs client (lambda (ns) (cons (cdr (assoc "n" item)) ns)) '())))
  (web-test/http:flood! pages 300)
  (check-equal? 4 (hashtable-size runs))
  (check (for-all (lambda (ns) (equal? (map 1+ (iota 300)) (reverse ns))) (vector->list (hashtable-values runs)))))

(define p (car pages))
(web-test/http:connect! p)
(define c (car (web:clients)))
(define seen (web-test/http:auto-confirm! p))

(define (last-seen) (let ([s (seen)]) (and (pair? s) (cdr (car (last-pair s))))))

(test "screens given as fast as the main thread can, while another thread confirms each, are numbered in turn, go forward, and the last arrives"
  (do ([i 1 (+ i 1)]) ((> i 2000))
    (web:send-screen! c (string->utf8 (number->string i)) "Tuna")
    (when (zero? (mod i 50)) (timers:sleep 0)))
  (test-runner:wait-until (lambda () (equal? '("2000") (last-seen))))
  (let ([s (seen)])
    (check-equal? (map 1+ (iota (length s))) (map car s))
    (check (let loop ([ns (map (lambda (x) (string->number (car (cdr x)))) s)])
             (or (null? (cdr ns)) (and (< (car ns) (cadr ns)) (loop (cdr ns))))))))

;; While the main thread itself waits busily, it keeps its own deadline.
(define (spin-until done?)
  (let ([deadline (add-duration (current-time 'time-monotonic) (make-time 'time-duration 0 30))])
    (let loop ()
      (unless (done?)
        (when (time>? (current-time 'time-monotonic) deadline)
          (errorf 'spin-until "~s did not hold within 30 s" done?))
        (loop)))))

;; A quit lands up to a thousand calls after it is asked for, and the
;; quitter's last request may come after the stress ends, so one guard
;; holds from before the quitter starts until well after it stops: a quit
;; landing between two guards would end the test. A quit that lands in
;; work after a batch is reported, as the kernel reports one, so the
;; reports of quits are counted with the quits.
(define (stress! seconds)
  (let* ([until (+ (real-time) (* 1000 seconds))] [quits 0] [quitting #t] [stopped #f] [forked #f]
         [count-quits (lambda (next e) (if (cancelled? e) (set! quits (+ quits 1)) (next e)))])
    (advice-add! report count-quits)
    (let again ()
      (guard (e [(cancelled? e) (set! quits (+ quits 1)) (again)])
        (unless forked
          (set! forked #t)
          (fork-task
            (lambda (restore)
              (let loop ()
                (if quitting
                    (begin
                      (request-quit!)
                      (chez:sleep (make-time 'time-duration 1000000 0))
                      (loop))
                    (set! stopped #t))))))
        (let loop ([i 0])
          (when (< (real-time) until)
            (web:send-screen! c (string->utf8 (string-append "q" (number->string i))) "Tuna")
            (when (zero? (mod i 1000)) (web:call-page! c "noop" i))
            (web:clients)
            (loop (+ i 1))))
        (set! quitting #f)
        (spin-until (lambda () stopped))
        (let settle ([n 0]) (when (< n 100000) (settle (+ n 1))))))
    (advice-remove! report count-quits)
    quits))

(test "quits landing while the main thread gives screens, calls pages and lists clients leave no lock held and no client half changed"
  (check (> (stress! 1) 10))
  (web:send-screen! c (haml (:p "after the quits")) "Tuna")
  (test-runner:wait-until (lambda () (equal? '((p "after the quits")) (last-seen))))
  (check-equal? 200 (web-test/http:status (web-test/http:get "/web/tuna.js"))))
