#!tuna
(import (buffers) (views) (layout) (commands) (keys))

(define-hook after-return "Called with the view after jump-history:go-back and jump-history:go-forward.")

(define-hook after-jump
  "Called with the view by a command that jumps to a place the user chose from a list or a lookup, as M-s l does, after it records the place left with jump-history:push!, and by a picker's preview after it shows a place.")

(define (recenter view) (views:scroll-to! view (views:point view) (views:align center)))

(define-option history-key (lambda (view) #f) procedure?
  "A procedure of the selected view that returns the key of the history to use, compared with eq?: #f for the one shared history, or jump-history:view-key for one per view.")

(define (view-key view) view)

(define-record-type %place
  (sealed #t)
  (fields buffer anchor))

(define-record-type %history
  (sealed #t)
  (fields (mutable back) (mutable forward)))

(define %shared (make-%history '() '()))

;; Weak, so a history goes with its key, as with a dropped view.
(define %keyed (make-weak-eq-hashtable))

(define (%history-of view)
  (let ([key (and view ((history-key) view))])
    (if key
        (or (eq-hashtable-ref %keyed key #f)
            (let ([h (make-%history '() '())])
              (eq-hashtable-set! %keyed key h)
              h))
        %shared)))

(define (%place-position p) (buffers:anchor-position (%place-anchor p)))

(define (%with-place places buffer position)
  (if (and (pair? places) (eq? (%place-buffer (car places)) buffer) (fx= (%place-position (car places)) position))
      places
      (cons (make-%place buffer (buffers:anchor buffer position)) places)))

(define (%push! view buffer position)
  (let ([h (%history-of view)])
    (%history-back-set! h (%with-place (%history-back h) buffer position))
    (%history-forward-set! h '())))

(define push!
  (case-lambda
    [(buffer position) (push! buffer position (layout:selected-view))]
    [(buffer position view)
     (unless (buffers:buffer? buffer)
       (assertion-violation 'jump-history:push! "not a buffer" buffer))
     (unless (and (integer? position) (exact? position) (>= position 0))
       (assertion-violation 'jump-history:push! "not a position" position))
     (unless (views:view? view)
       (assertion-violation 'jump-history:push! "not a view" view))
     (unless (%internal? buffer)
       (%push! view buffer position))]))

(define %returning? (make-thread-parameter #f))

(define (%internal? b) (buffers:internal-name? (buffers:name b)))

(define (record-switch view left point)
  (unless (or (%returning?) (not (commands:this-command)) (%internal? left))
    (%push! view left point)))

(define (places)
  (map (lambda (p) (cons (%place-buffer p) (%place-position p)))
       (%history-back (%history-of (layout:selected-view)))))

(define (%go! place)
  (parameterize ([%returning? #t])
    (layout:switch-to-buffer (%place-buffer place)))
  (let ([view (layout:selected-view)])
    (views:set-point! view (%place-position place))
    (after-return view)))

(commands:define-command (go-back)
  "Goes back to the newest place a jump left, keeping point to come forward to with jump-history:go-forward."
  (let* ([view (layout:selected-view)] [h (%history-of view)] [back (%history-back h)])
    (when (null? back)
      (error 'jump-history:go-back "At start of jump history"))
    (%history-back-set! h (cdr back))
    (unless (%internal? (views:buffer view))
      (%history-forward-set! h (%with-place (%history-forward h) (views:buffer view) (views:point view))))
    (%go! (car back))))

(commands:define-command (go-forward)
  "Goes forward to the place jump-history:go-back left, keeping point to go back to."
  (let* ([view (layout:selected-view)] [h (%history-of view)] [forward (%history-forward h)])
    (when (null? forward)
      (error 'jump-history:go-forward "At end of jump history"))
    (%history-forward-set! h (cdr forward))
    (unless (%internal? (views:buffer view))
      (%history-back-set! h (%with-place (%history-back h) (views:buffer view) (views:point view))))
    (%go! (car forward))))

(define (%forget-buffer! b)
  (define (kept places) (remp (lambda (p) (eq? (%place-buffer p) b)) places))
  (for-each
    (lambda (h)
      (%history-back-set! h (kept (%history-back h)))
      (%history-forward-set! h (kept (%history-forward h))))
    (cons %shared (vector->list (hashtable-values %keyed)))))

(add-hook! after-jump recenter)
(add-hook! layout:after-switch-to-buffer record-switch)
(add-hook! buffers:killed %forget-buffer!)
(keys:bind! keys:global "M-," go-back)
(keys:bind! keys:global "C-M-," go-forward)
