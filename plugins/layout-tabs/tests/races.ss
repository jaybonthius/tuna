(import (tuna) (test) (test-user) (layout) (layout-split) (layout-tabs) (views) (buffers) (document) (plugins)
        (layout-tabs-test parts) (test-runner)
        (rename (only (chezscheme) sleep) (sleep chez:sleep)))

(define request-quit! (test-runner:running-task-canceller))

(define tree layout-tabs-test/parts:tree)

(define notes (buffers:make "notes" "one\ntwo\nthree\n"))

(define (atom-ids d)
  (if (vector? d) (list (cdr (assq 'view (vector-ref d 1)))) (apply append (map atom-ids (cddr d)))))

(define (pick ls k) (list-ref ls (mod k (length ls))))

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
(define (stress! seconds step)
  (let* ([until (+ (real-time) (* 1000 seconds))] [quits 0] [quitting #t] [stopped #f] [forked #f] [k 0]
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
          (when (< (real-time) until)
            (guard (c [(error? c) #f]) (step k))
            (set! k (+ k 1))
            (loop)))
        (set! quitting #f)
        (spin-until (lambda () stopped))
        (let settle ([n 0]) (when (< n 100000) (settle (+ n 1))))))
    (advice-remove! report count-quits)
    quits))

;; A plugin asks before it deletes or adds beside a part, as the API's
;; refusals are faults of its caller.
(define (delete! node) (unless (layout:deletion-refusal node) (layout:delete-part! node)))

(define (unlocked? view) (not (layout:locked? (layout:view-node view))))

(define (click p) (list "<mouse-1>" (views:%make-posn layout:screen-view p)))

(define (tabs-step k)
  (let* ([shown (layout:views)] [selected (layout:selected-view)] [many? (> (length (atom-ids (tree))) 12)]
         [size (document:length (buffers:document layout:buffer))])
    (case (mod k 14)
      [(0) (if many? (layout-tabs:close-tab) (layout-tabs:new-tab))]
      [(1) (cond [many? (delete! (layout:view-node (pick shown k)))] [(unlocked? selected) (layout-tabs:add-tab! selected notes)])]
      [(2) (when (unlocked? selected) (layout-split:split-view! selected (layout-split:direction row)))]
      [(3) (layout-tabs:next-tab (- (mod k 7) 3))]
      [(4) (layout-tabs:previous-tab (mod k 3))]
      [(5) (layout:zoom #f)]
      [(6) (layout:screen (test-user:client))]
      [(7) (layout-tabs:mouse-select-tab (click (mod (* k 13) size)))]
      [(8) (layout-tabs:display-in-new-tab notes)]
      [(9) (when (pair? (layout:other-views)) (layout:other-view 1))]
      [(10) (layout-tabs:close-tab)]
      [(11) (layout-tabs:close-other-tabs)]
      [(12) (layout-tabs:recent-tab (+ 1 (mod k 2)))]
      [else (layout:select! (pick shown (* k 7)))])))

(define (whole? d)
  (or (and (vector? d) (eq? (vector-ref d 0) 'views:view) (fixnum? (cdr (assq 'view (vector-ref d 1)))))
      (and (pair? d) (pair? (cddr d)) (for-all whole? (cddr d)))))

(define (ids-once? ids) (or (null? ids) (and (not (memv (car ids) (cdr ids))) (ids-once? (cdr ids)))))

(test "quits landing in the tab commands, clicks and draws leave the layout whole, and reloads of layout-tabs and layout find it as it was"
  (layout-tabs-test/parts:set-parts! (layout-tabs-test/parts:atom (views:make notes)))
  (layout:select! (car (layout:views)))
  (check (> (stress! 2 tabs-step) 100))
  (check (whole? (tree)))
  (check (ids-once? (atom-ids (tree))))
  (check (layout:view-node (layout:selected-view)))
  (check (memq (layout:selected-view) (layout:views)))
  (check (for-all (lambda (id) (let ([v (views:find id)]) (and v (buffers:live? (views:buffer v))))) (atom-ids (tree))))
  (test-user:settle)
  (check-equal? 1 (length (test-user:elements (test-user:screen) "layout-screen")))
  (let ([before (list (tree) (layout:selected-view) (layout:views))])
    (reload-modules! '((layout-tabs)))
    (check-equal? before (list (tree) (layout:selected-view) (layout:views)))
    (reload-modules! '((layout)))
    (check-equal? before (list (tree) (layout:selected-view) (layout:views)))))
