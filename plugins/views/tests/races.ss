(import (tuna) (test) (views) (buffers) (document) (options) (tables) (web) (plugins) (test-user)
        (views-test page) (views-test text) (views-test md) (views-test quits)
        (rename (only (chezscheme) sleep) (sleep chez:sleep)))

(options:set! views:scroll-margin 2 views:wrap-lines #f)

(define text (buffers:make (buffers:free-name "text") (views-test/text:lines 400)))
(define host (buffers:make (buffers:free-name "*host*")
               (views-test/md:doc '() (views:view `((view . 50) (buffer . ,(buffers:name text)))))))
(define atom (views:atom-view (document:token (buffers:document host) 1)))
(define plain (views:make text))
(define all (list atom plain))
(define desktop (views-test/page:open 400))
(define phone (views-test/page:open 200))

(define (scroll-report! page view k)
  (let ([c (views-test/page:client page)])
    (parameterize ([web:current-client c])
      ((tables:ref web:input-handlers "scroll") c
       (views-test/page:report-item page view (+ 1 (mod k 300)) (mod k 7) (odd? (quotient k 9)))))))

(define (step! k)
  (let* ([v (list-ref all (mod k 2))]
         [size (document:length (buffers:document text))]
         [p (+ 1 (mod (* k 7919) (- size 2)))])
    (case (mod k 9)
      [(0) (views:set-point! v p)]
      [(1) (buffers:replace! text p p "abcdef\n")]
      [(2) (views:fold! v p (min (- size 1) (+ p 30)))]
      [(3) (views:unfold! v p)]
      [(4) (scroll-report! (if (even? k) desktop phone) v k)]
      [(5) (if (null? (cdr (views:cursors v))) (views:add-cursor! v p) (views:remove-cursor! v (cadr (views:cursors v))))]
      [(6) (buffers:replace! text p (min (- size 1) (+ p 5)) "")]
      [(7) (views:scroll-to! v p (views:align center))
           (when (zero? (mod k 63))
             (web:close-client! (views-test/page:client phone))
             (set! phone (views-test/page:open 200)))]
      [else (views:draw v (views-test/page:client (if (even? k) desktop phone)))])))

;; A quit lands up to a thousand calls after its request, and the
;; quitter's last request may come after the stress ends, so one guard
;; holds from before the quitter starts until well after it stops: a quit
;; landing between two guards would end the test. Quits land at least a
;; thousand calls apart, so none lands in the handler before it enters
;; the guard again.
(define (stress! seconds)
  (let ([until (+ (real-time) (* 1000 seconds))] [quits 0] [quitting #t] [stopped #f] [forked #f])
    (let again ()
      (guard (c [(cancelled? c) (set! quits (+ quits 1)) (again)])
        (unless forked
          (set! forked #t)
          (fork-task
            (lambda (restore)
              (let loop ()
                (if quitting
                    (begin
                      (views-test/quits:request-quit!)
                      (chez:sleep (make-time 'time-duration 1000000 0))
                      (loop))
                    (set! stopped #t))))))
        (let loop ([k 0])
          (when (< (real-time) until)
            (step! k)
            (loop (+ k 1))))
        (set! quitting #f)
        (let spin () (unless (or stopped (> (real-time) (+ until 30000))) (spin)))
        (let settle ([n 0]) (when (< n 100000) (settle (+ n 1))))))
    quits))

(define (whole? v)
  (let-values ([(lo hi) (views:bounds v)])
    (and (eq? (views:find (views:id v)) v)
         (eq? (views:buffer v) text)
         (for-all (lambda (c) (let ([p (views:cursor-point c)]) (and (<= lo p hi) (eqv? (buffers:stop text p) p))))
                  (views:cursors v)))))

(test "quits landing in cursor moves, folds, edits, scroll reports, draws and removals leave every view whole and drawing"
  (let ([quiet (lambda (next c) (unless (cancelled? c) (next c)))])
    (advice-add! report quiet)
    (check (> (stress! 2) 100))
    (test-user:settle)
    (advice-remove! report quiet))
  (check (for-all whole? all))
  (check (for-all (lambda (v) (views-test/page:view-element desktop v)) all)))

(test "after the quits, the view drawn from an atom comes back from saved data as it is"
  (let ([before (list (views:point atom) (map views:cursor-point (views:cursors atom)))])
    (test-user:settle)
    (reload-modules! '((views)))
    (let ([v (views:find 50)])
      (check-equal? before (list (views:point v) (map views:cursor-point (views:cursors v)))))))
