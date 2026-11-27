(import (tuna) (test) (layout) (layout-scroll) (layout-float) (views) (buffers) (document) (tables) (web) (plugins)
        (haml) (test-user) (layout-float-test quits) (rename (only (chezscheme) sleep) (sleep chez:sleep)))

(define (lines name n)
  (apply string-append (map (lambda (i) (format "~a ~a\n" name (+ i 1))) (iota n))))

(define (atom view)
  (views:view (list (cons 'view (views:id view)) (cons 'buffer (buffers:name (views:buffer view))))))

(define (tree) (car (document:datums (buffers:document layout:buffer))))
(define (popups) (car (document:datums (buffers:document layout:popups-buffer))))

(define notes (buffers:make (buffers:free-name "notes") (lines "n" 80)))
(define completions (buffers:make (buffers:free-name "*completions*") "one\ntwo\n"))
(define question (buffers:make (buffers:free-name "*question*") "?\n"))
(define desktop (test-user:client))
(define phone (test-user:open-client))

(let ([n (document:length (buffers:document layout:buffer))])
  (buffers:replace! layout:buffer 1 (- n 1)
    (document:from-datum
      (layout-scroll:container '() (atom (views:make notes)) (atom (views:make notes))
        (layout-float:container '() (atom (views:make notes)))))))
(test-user:settle)

(define (atom-ids d)
  (if (vector? d) (list (cdr (assq 'view (vector-ref d 1)))) (apply append (map atom-ids (cddr d)))))

(define (all-ids) (append (atom-ids (tree)) (apply append (map atom-ids (cddr (popups))))))

(define (pick ls k) (list-ref ls (mod k (length ls))))

(define %reports 0)

(define (strip-report! client shown k)
  (let ([scrollers (test-user:elements-with (html->sxml (layout:screen client)) "data-scroller")])
    (unless (null? scrollers)
      (set! %reports (+ %reports 1))
      (let ([s (car scrollers)] [focus (views:id (pick shown k))])
        ((tables:ref web:input-handlers "scroller") client
         `(("type" . "scroller") ("scroller" . ,(string->number (test-user:element-attribute s "data-scroller")))
           ("placement" . ,(string->number (test-user:element-attribute s "data-placement"))) ("report" . ,%reports)
           ("items" . ,(list->vector (map views:id shown))) ("whole" . ,(list->vector (map views:id shown))) ("settled" . #t)
           ("item" . ,focus) ("align" . "start") ("focus" . ,focus)))))))

;; The commands refuse many of these steps, as a locked part or no strip;
;; only a quit is the storm's.
(define (attempt thunk) (guard (c [(not (cancelled? c)) #f]) (thunk)))

(define (step! k)
  (let* ([shown (layout:views)] [many? (> (length (atom-ids (tree))) 10)])
    (attempt
      (lambda ()
        (case (mod k 16)
          [(0) (if many? (layout:delete-part! (layout:view-node (pick shown k))) (layout-scroll:display-in-new-column notes))]
          [(1) (layout-scroll:consume)]
          [(2) (layout-scroll:expel)]
          [(3) (if (even? k) (layout-scroll:consume-or-expel-left) (layout-scroll:consume-or-expel-right))]
          [(4) (layout-scroll:cycle-size)]
          [(5) (layout-scroll:full-size)]
          [(6) (layout:screen desktop) (layout:screen phone)]
          [(7) (strip-report! desktop shown k)]
          [(8) (layout-float:toggle)]
          [(9) (layout-float:cycle)]
          [(10) (let ([palettes (views:showing question)])
                  (layout-float:show-at! (if (and (odd? k) (pair? palettes)) (car palettes) (pick shown k))
                                         1 completions 1/2 '(lines 4)))]
          [(11) (let ([p (find (lambda (v) (eq? (views:buffer v) completions)) (views:showing completions))])
                  (when p (layout-float:close! p)))]
          [(12) (layout:select! (layout-float:display-palette question))]
          [(13) (layout:other-view)]
          [(14) (if (even? k) (layout-scroll:first) (layout-scroll:last))]
          [else (layout:select! (pick shown (* k 7)))])))))

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
                      (layout-float-test/quits:request-quit!)
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

(define (parts-only? d)
  (or (and (vector? d) (eq? (vector-ref d 0) 'views:view) (fixnum? (cdr (assq 'view (vector-ref d 1)))))
      (and (pair? d) (pair? (cddr d)) (for-all parts-only? (cddr d)))))

(define (once? ids) (or (null? ids) (and (not (memv (car ids) (cdr ids))) (once? (cdr ids)))))

(test "quits landing in every strip and float command, draws and scroll reports leave the layout and the popups whole"
  (let ([quiet (lambda (next c) (unless (cancelled? c) (next c)))])
    (advice-add! report quiet)
    (check (> (stress! 2) 100))
    (test-user:settle)
    (advice-remove! report quiet))
  (check (parts-only? (tree)))
  (check (for-all parts-only? (cddr (popups))))
  (check (once? (all-ids)))
  (let ([v (layout:selected-view)])
    (check (or (layout:view-node v) (memv (views:id v) (all-ids)))))
  (check (for-all (lambda (id) (let ([v (views:find id)]) (and v (buffers:live? (views:buffer v))))) (all-ids)))
  (check (pair? (test-user:elements (test-user:screen desktop) "layout-screen"))))

(test "after the quits, a reload of layout-scroll keeps the layout, one of layout-float closes the popups, and one of layout keeps the layout"
  (let ([before (list (tree) (popups) (views:id (layout:selected-view)) (map views:id (layout:views)))])
    (reload-modules! '((layout-scroll)))
    (check-equal? before (list (tree) (popups) (views:id (layout:selected-view)) (map views:id (layout:views)))))
  (let ([before (tree)])
    (reload-modules! '((layout-float)))
    (check-equal? before (tree))
    (check-equal? '(layout:popups-root ()) (popups)))
  (let ([before (list (tree) (views:id (layout:selected-view)) (map views:id (layout:views)))])
    (reload-modules! '((layout)))
    (check-equal? before (list (tree) (views:id (layout:selected-view)) (map views:id (layout:views))))
    (let ([c (test-user:open-client)])
      (test-user:settle)
      (check (pair? (test-user:elements (test-user:screen c) "layout-screen"))))))
