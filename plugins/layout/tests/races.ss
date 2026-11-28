(import (tuna) (test) (test-user) (layout) (layout-split) (layout-tabs) (layout-scroll) (layout-float) (views) (buffers)
        (document) (haml) (web) (plugins) (timers) (commands)
        (layout-test parts) (test-runner)
        (rename (only (chezscheme) sleep) (sleep chez:sleep)))

(define request-quit! (test-runner:running-task-canceller))

(define atom layout-test/parts:atom)
(define tree layout-test/parts:tree)

(define notes (buffers:make "notes" "one\ntwo\nthree\n"))
(define side (buffers:make "side" ""))

(define (atom-ids d)
  (if (vector? d) (list (cdr (assq 'view (vector-ref d 1)))) (apply append (map atom-ids (cddr d)))))

(define (pick ls k) (list-ref ls (mod k (length ls))))

;; A step may be refused, as a user's command is, but any other raise is
;; a fault the stress found.
(define (attempt thunk) (guard (c [(error? c) #f]) (thunk)))

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
;; reports of quits are counted with the quits and any other report
;; passes on.
(define (stress! going? step)
  (let* ([quits 0] [quitting #t] [stopped #f] [forked #f] [k 0]
         [count-quits (lambda (next c) (if (cancelled? c) (set! quits (+ quits 1)) (next c)))])
    (advice-add! report count-quits)
    (let again ()
      (guard (c [(cancelled? c) (set! quits (+ quits 1)) (again)])
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
        (let loop ()
          (when (going?)
            (attempt (lambda () (step k)))
            (set! k (+ k 1))
            (loop)))
        (set! quitting #f)
        (spin-until (lambda () stopped))
        (let settle ([n 0]) (when (< n 100000) (settle (+ n 1))))))
    (advice-remove! report count-quits)
    quits))

(define (for-seconds seconds)
  (let ([until (+ (real-time) (* 1000 seconds))])
    (lambda () (< (real-time) until))))

(define (whole? d)
  (or (and (vector? d) (eq? (vector-ref d 0) 'views:view) (fixnum? (cdr (assq 'view (vector-ref d 1)))))
      (and (pair? d) (pair? (cddr d)) (for-all whole? (cddr d))
           (or (not (eq? (car d) 'layout:level))
               (and (null? (cdddr d)) (not (and (pair? (caddr d)) (eq? (car (caddr d)) 'layout:level))))))))

(define (ids-once? ids) (or (null? ids) (and (not (memv (car ids) (cdr ids))) (ids-once? (cdr ids)))))

(define (live-views?)
  (for-all (lambda (id) (let ([v (views:find id)]) (and v (buffers:live? (views:buffer v))))) (atom-ids (tree))))

(define (drawn?)
  (test-user:settle)
  (= 1 (length (test-user:elements (test-user:screen) "layout-screen"))))

;; A plugin asks before it deletes or splits a part, as the API's
;; refusals are faults of its caller.
(define (delete! node) (unless (layout:deletion-refusal node) (layout:delete-part! node)))

(define (split! view direction) (unless (layout:locked? (layout:view-node view)) (layout-split:split-view! view direction)))

(define (window-step k)
  (let* ([shown (layout:views)] [selected (layout:selected-view)] [many? (> (length (atom-ids (tree))) 10)])
    (case (mod k 14)
      [(0) (if many? (delete! (layout:view-node (pick shown k))) (split! selected (layout-split:direction row)))]
      [(1) (if many? (delete! (layout:view-node (pick shown k))) (split! selected (layout-split:direction column)))]
      [(2) (delete! (layout:view-node (pick shown (* k 31))))]
      [(3) (layout:select! (pick shown (* k 7)))]
      [(4) (layout:zoom (if (even? (div k 13)) #f '(4)))]
      [(5) (layout:screen (test-user:client))]
      [(6) (layout-split:enlarge (- (mod k 5) 2))]
      [(7) (layout:display-buffer notes)]
      [(8) (when (pair? (layout:other-views)) (layout:other-view 1))]
      [(9) (layout-split:balance)]
      [(10) (let ([v (layout:find-view side)])
              (if v
                  (delete! (layout:view-node v))
                  ((layout-split:display-at-side (pick (list (layout:direction left) (layout:direction right) (layout:direction up) (layout:direction down)) k)
                     50 'content '((locked . #t)))
                   side)))]
      [(11) (when many? (layout:reset-layout))]
      [(12) (case (mod (div k 14) 3)
              [(0) (unless (or many? (layout:locked? (layout:view-node selected))) (commands:run layout-split:split-right))]
              [(1) (layout:history-back)]
              [else (layout:history-forward)])]
      [else (layout:neighbour selected (pick (list (layout:direction left) (layout:direction right) (layout:direction up) (layout:direction down)) k))])))

(test "quits landing in window commands, selections, zooms, displays and draws leave the layout whole, and a reload of layout finds it as it was"
  (layout-test/parts:set-parts! (atom (views:make notes)))
  (check (> (stress! (for-seconds 2) window-step) 100))
  (check (whole? (tree)))
  (check (ids-once? (atom-ids (tree))))
  (check (layout:view-node (layout:selected-view)))
  (check (pair? (layout:views)))
  (check (live-views?))
  (check (drawn?))
  (let ([before (list (tree) (layout:selected-view) (layout:views))])
    (reload-modules! '((layout)))
    (check-equal? before (list (tree) (layout:selected-view) (layout:views)))))

(define (part-mode-step k)
  (case (mod k 20)
    [(0) (layout:select-parent)]
    [(1) (layout:select-child)]
    [(2) (layout:select-previous)]
    [(3) (layout:select-next)]
    [(4) (layout:shift-backward)]
    [(5) (layout:shift-forward)]
    [(6) (layout:lift)]
    [(7) (layout:lower)]
    [(8) (if (> (length (atom-ids (tree))) 3) (layout:raise) (layout-split:split-right #f))]
    [(9) (layout:splice)]
    [(10) (if (> (length (atom-ids (tree))) 3) (layout:delete-view) (layout-scroll:display-in-new-column notes))]
    [(11) (case (mod k 4)
            [(0) (layout-split:wrap-in-row)]
            [(1) (layout-tabs:wrap-in-tabs)]
            [(2) (layout-scroll:wrap-in-strip)]
            [else (layout-float:wrap-in-float)])]
    [(12) (layout:wrap-in-level)]
    [(13) (case (mod k 4)
            [(0) (layout:zoom (if (even? (div k 4)) #f '(4)))]
            [(1) (when (pair? (layout:other-views)) (layout:other-view 1))]
            [(2) ((layout-split:display-at-side (layout:direction left) 50 '(columns 20)) side)]
            [else (let ([v (layout:find-view side)]) (when v (layout:delete-part! (layout:view-node v))))])]
    [(14) (layout:screen (test-user:client))]
    [(15) (layout:part-mode-leave) (layout:part-mode)]
    [(16) (layout-split:split-below #f)]
    [(17) (layout:select-first)]
    [(18) (layout:select-last)]
    [else (batch-ended)]))

(test "quits landing in the part mode's moves, wraps, splices, raises and draws leave the layout whole and a part selected, and a reload of layout ends the mode"
  (let ([fresh (lambda () (atom (views:make notes)))])
    (layout-test/parts:set-parts!
      (layout-split:container '((direction . row)) (fresh)
        (layout-scroll:container '() (fresh) (layout-split:container '((direction . column)) (fresh) (fresh)))
        (layout-float:container '() (fresh)))))
  (layout:part-mode)
  (check (> (stress! (for-seconds 2) part-mode-step) 100))
  (batch-ended)
  (check (whole? (tree)))
  (check (ids-once? (atom-ids (tree))))
  (check (live-views?))
  (let ([n (layout:selected-part)] [doc (buffers:document layout:buffer)])
    (check (layout:part-mode?))
    (check (document:node? n))
    (check (< 0 (document:node-start n) (document:node-end n) (document:length doc))))
  (check (layout:view-node (layout:selected-view)))
  (check (drawn?))
  (let ([before (list (tree) (layout:selected-view))])
    (reload-modules! '((layout)))
    (check-equal? before (list (tree) (layout:selected-view)))
    (check (not (layout:part-mode?)))))

(test "quits landing in draws are never reported as errors, drawing goes on, and once they stop every client shows the newest screen"
  (let* ([phone (test-user:open-client)] [n 0] [started 0] [finished 0] [storming #t]
         ;; A draw takes less time than the quitter sleeps, and under load
         ;; the steps keep in time with the quits, which end each step's
         ;; pause, so a quit would seldom find a draw running. Each draw
         ;; waits for one instead.
         [heavy (lambda (screen client)
                  (set! started (+ started 1))
                  (let ([s (haml (:div (:p.newest "n " n)))] [until (+ (real-time) 50)])
                    (let wait () (when (and storming (< (real-time) until)) (wait)))
                    (set! finished (+ finished 1))
                    s))]
         [newest (lambda (c) (test-user:element-text (car (test-user:elements (test-user:screen c) "newest"))))]
         [until (+ (real-time) 1500)])
    (advice-add! layout:screen heavy)
    (stress! (lambda () (and (< (real-time) (+ until 20000)) (or (< (real-time) until) (<= (- started finished) 100))))
      (lambda (k) (set! n (+ n 1)) (timers:sleep 0)))
    (set! storming #f)
    (check (> (- started finished) 100))
    (test-user:settle)
    (check-equal? (list (format "n ~a" n) (format "n ~a" n)) (list (newest (test-user:client)) (newest phone)))
    (advice-remove! layout:screen heavy)
    (let* ([fails (lambda (screen c) (if (eq? c phone) (car '()) (screen c)))]
           [reported (test-runner:reports-during
                       (lambda () (advice-add! layout:screen fails) (test-user:settle) (test-user:settle) (advice-remove! layout:screen fails)))])
      (check-equal? 1 (length reported)))
    (web:close-client! phone)))
