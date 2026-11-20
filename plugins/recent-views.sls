#!tuna
(import (layout) (commands))

(define-option delay 1.5 (lambda (v) (and (real? v) (finite? v) (not (negative? v))))
  "Seconds a view must stay selected to get its tick, which also ends the cycle of recent-views:select-recent-view.")

;; As switchy-window, the order is the plugin's own: a selection counts
;; only once the view has stayed selected for the delay, so the views a
;; cycle or C-x o passes through keep their places.
(define %ticks (make-weak-eq-hashtable))
(define %count 0)
(define %visited '())
(define %seen #f)
(define %timer #f)

(define (%tick! view)
  (set! %count (+ %count 1))
  (eq-hashtable-set! %ticks view %count))

(define (%end-cycle!)
  (%tick! (layout:selected-view))
  (set! %visited '()))

(define (%note-selection command)
  (let ([view (layout:selected-view)])
    (unless (eq? view %seen)
      (set! %seen view)
      (when %timer (cancel-timer! %timer))
      (set! %timer (run-with-timer (delay) (lambda () (set! %timer #f) (%end-cycle!)))))))

(define (%pick views oldest?)
  (let ([tick (lambda (v) (eq-hashtable-ref %ticks v 0))])
    (fold-left (lambda (best v) (if ((if oldest? < >) (tick v) (tick best)) v best)) (car views) (cdr views))))

(define (%select! oldest?)
  (let* ([selected (layout:selected-view)]
         [candidates (remp (lambda (v) (or (eq? v selected) (memq v %visited))) (layout:other-views))])
    (unless (memq selected %visited)
      (set! %visited (cons selected %visited)))
    (cond
      [(pair? candidates)
       (let ([view (%pick candidates oldest?)])
         (set! %visited (cons view %visited))
         (layout:select! view))]
      [(pair? (cdr %visited))
       (set! %visited '())
       (%select! oldest?)])))

(commands:define-command (select-recent-view [oldest? (and (commands:prefix-argument) #t)])
  "Selects the view selected most recently before this one, by recent-views' ticks; run again within recent-views:delay seconds, the next in that order, each view once a cycle. With a prefix argument, the one selected least recently."
  (unless (eq? (commands:last-command) select-recent-view)
    (%end-cycle!))
  (%select! oldest?))

(add-hook! commands:after-command %note-selection)
