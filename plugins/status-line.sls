#!tuna
(import (buffers) (document) (views) (layout) (keys) (commands) (modes) (web) (haml))

(define-option visible #t boolean? "Whether a view has a status line.")

(define-table segments
  "Where segments show: each segment's place, from status-line:left or status-line:right.")

(define-table keymap "The keymap of the status line, searched after its segments' keymaps.")

;; Tables, so unloading the module that defines a segment takes back its
;; kind name and show procedure.
(define-table %segment-kinds)

(define-table %shows)

(buffers:define-kind line (keymap keymap))

(module %internals
  (check-main-thread check-view make-place place-record? place-side place-n status-view window-of posn-window shown-html
   write-line! forget-windows! drop-status-views! kill-status-buffer! note-kill!)

  (define main-thread (get-thread-id))

  (define (check-main-thread who)
    (unless (fx= (get-thread-id) main-thread)
      (assertion-violation who "not on the main thread")))

  (define (check-view who v)
    (unless (views:view? v)
      (assertion-violation who "not a view" v)))

  ;; Places made by the configuration outlive a reload of this module, so
  ;; the record type stays the same.
  (define-record-type (place make-place place-record?)
    (nongenerative status-line:place/side/n)
    (sealed #t)
    (fields side n))

  (define line-buffer #f)

  (define (status-buffer)
    (unless (and line-buffer (buffers:live? line-buffer))
      (set! line-buffer (or (buffers:find " *status-line*") (buffers:make " *status-line*" (line '()))))
      (buffers:with-buffer line-buffer (set-option-local! views:cursor-visible #f))
      (set! written #f))
    line-buffer)

  (define (kill-status-buffer!)
    (when (and line-buffer (buffers:live? line-buffer))
      (buffers:kill! line-buffer)))

  ;; Views shows another buffer in the views of a killed one, so the
  ;; status views go with the line and are made again on the next.
  (define (note-kill! b)
    (when (eq? b line-buffer)
      (forget-windows! (lambda (w id) #f))))

  ;; A window's entry keeps its number, since a dropped view no longer
  ;; tells it. A view is made or dropped with its entries with interrupts
  ;; off, so a quit cannot leave a status view that no entry names.
  (define status-views (make-eq-hashtable))
  (define windows (make-eq-hashtable))

  (define (status-view window)
    (let ([entry (eq-hashtable-ref status-views window #f)])
      (if entry
          (cdr entry)
          (let ([b (status-buffer)])
            (with-interrupts-disabled
              (let ([v (views:make b)])
                (eq-hashtable-set! status-views window (cons (views:id window) v))
                (eq-hashtable-set! windows v window)
                v))))))

  (define (window-of v) (eq-hashtable-ref windows v #f))

  (define (posn-window posn) (let ([v (views:posn-view posn)]) (and v (window-of v))))

  (define (forget-windows! keep?)
    (let-values ([(ws entries) (hashtable-entries status-views)])
      (vector-for-each
        (lambda (w entry)
          (unless (keep? w (car entry))
            (with-interrupts-disabled
              (eq-hashtable-delete! status-views w)
              (eq-hashtable-delete! windows (cdr entry))
              (views:drop! (cdr entry)))))
        ws entries)))

  (define (drop-status-views!)
    (forget-windows! (lambda (w id) (eq? (views:find id) w))))

  ;; A show procedure that raises is reported once for its window, until
  ;; it shows again without raising, rather than at every draw.
  (define failing (make-weak-eq-hashtable))

  (define (show-failed! kind window c)
    (let ([kinds (eq-hashtable-ref failing window '())])
      (unless (memq kind kinds)
        (eq-hashtable-set! failing window (cons kind kinds))
        (report c)))
    #f)

  (define (shown-html kind show window)
    (guard (c [(not (quit-condition? c)) (show-failed! kind window c)])
      (let ([r (views:with-view window (show window))])
        (cond
          [(or (not r) (string? r) (html? r))
           (let ([kinds (eq-hashtable-ref failing window '())])
             (when (memq kind kinds)
               (eq-hashtable-set! failing window (remq kind kinds))))
           r]
          [else
           (show-failed! kind window
             (condition (make-assertion-violation) (make-who-condition kind)
               (make-message-condition "a show procedure returned what is not HTML, a string or #f")
               (make-irritants-condition (list r))))]))))

  (define written #f)

  ;; Only the entries misplaced now are kept, so each is reported once
  ;; while it stays and the list does not grow.
  (define misplaced '())

  (define (report-misplaced! entries)
    (for-each
      (lambda (e)
        (unless (exists (lambda (m) (and (eq? (car m) (car e)) (eq? (cdr m) (cdr e)))) misplaced)
          (report (condition (make-assertion-violation) (make-who-condition 'status-line:segments)
                    (make-message-condition "not a place") (make-irritants-condition (list (cdr e)))))))
      entries)
    (set! misplaced entries))

  (define (placed side entries)
    (list-sort (lambda (a b) (< (place-n (cdr a)) (place-n (cdr b))))
               (filter (lambda (e) (eq? (place-side (cdr e)) side)) entries)))

  ;; Equal numbers keep the order of table-entries, the order first
  ;; placed, since list-sort is stable.
  (define (line-datums)
    (let* ([bad '()]
           [entries (fold-right
                      (lambda (e acc)
                        (let ([name (table-ref %segment-kinds (car e) #f)])
                          (cond
                            [(not name) acc]
                            [(place-record? (cdr e)) (cons (cons name (cdr e)) acc)]
                            [else (set! bad (cons e bad)) acc])))
                      '() (table-entries segments))]
           [left (placed 'left entries)] [right (placed 'right entries)])
      (report-misplaced! bad)
      (append
        (map (lambda (e) (vector (car e) (list (cons 'key (car e))))) left)
        (let loop ([right right] [first? #t])
          (if (null? right)
              '()
              (cons (vector (caar right) (if first? (list (cons 'key (caar right)) '(right . #t)) (list (cons 'key (caar right)))))
                    (loop (cdr right) #f)))))))

  (define (write-line!)
    (let ([b (status-buffer)] [datums (line-datums)])
      (unless (equal? datums written)
        (buffers:reconcile! b (document:token (buffers:document b) 0) datums)
        (set! written datums)))))

(import %internals)

(define (%register-segment! constructor show)
  (unless (procedure? show)
    (assertion-violation 'status-line:define-segment "not a procedure" show))
  (let ([name (buffers:kind-name (buffers:constructor-kind constructor))])
    (table-set! %segment-kinds constructor name)
    (table-set! %shows name show)))

(define (%draw-segment node view)
  (let* ([kind (document:node-kind node)] [window (window-of view)] [show (table-ref %shows kind #f)]
         [entry (buffers:kind kind)] [content (or (and window show (shown-html kind show window)) (list))]
         [right (and (document:node-attribute node 'right #f) "status-line-right")])
    (if (and entry (buffers:kind-keymap entry))
        (haml (:button.status-line-segment ([type "button"] [tabindex "-1"] [class right] [data-segment (symbol->string kind)])
                content))
        (haml (:span.status-line-segment ([class right] [data-segment (symbol->string kind)])
                content)))))

(define-syntax define-segment
  (lambda (x)
    (define (invalid c) (syntax-violation 'status-line:define-segment "invalid clause" x c))
    (syntax-case x ()
      [(_ id clause ...)
       (identifier? #'id)
       (let loop ([clauses #'(clause ...)] [seen '()] [show #f] [keymap #'#f])
         (if (null? clauses)
             (begin
               (unless show
                 (syntax-violation 'status-line:define-segment "a show clause is required" x))
               #`(begin
                   (buffers:define-kind id (content atom) (draw %draw-segment) (keymap #,keymap))
                   (define-values () (begin (%register-segment! id #,show) (values)))))
             (let* ([c (car clauses)]
                    [name (syntax-case c () [(k . _) (identifier? #'k) (syntax->datum #'k)] [_ (invalid c)])])
               (when (memq name seen)
                 (syntax-violation 'status-line:define-segment "clause given twice" x c))
               (let ([e (syntax-case c () [(_ e) #'e] [_ (invalid c)])])
                 (case name
                   [(show) (loop (cdr clauses) (cons name seen) e keymap)]
                   [(keymap) (loop (cdr clauses) (cons name seen) show e)]
                   [else (invalid c)])))))]
      [_ (syntax-violation 'status-line:define-segment "expected (status-line:define-segment id clause ...)" x)])))

(define (left n)
  (unless (real? n)
    (assertion-violation 'status-line:left "not a real number" n))
  (make-place 'left n))

(define (right n)
  (unless (real? n)
    (assertion-violation 'status-line:right "not a real number" n))
  (make-place 'right n))

(define (place? v) (place-record? v))

(define (posn-view posn)
  (check-main-thread 'status-line:posn-view)
  (posn-window posn))

(define (draw view client)
  (check-view 'status-line:draw view)
  (unless (or (not client) (web:client? client))
    (assertion-violation 'status-line:draw "not a client or #f" client))
  (check-main-thread 'status-line:draw)
  (and (layout:view-node view)
       (haml (:footer.status-line (views:draw (status-view view) client)))))

(commands:define-command (mouse-select-view [event (keys:command-event)])
  "Selects the view whose status line was clicked, unless it is locked."
  (unless (keys:event? event)
    (assertion-violation 'status-line:mouse-select-view "not an event" event))
  (let* ([window (posn-view (keys:event-start event))] [node (and window (layout:view-node window))])
    (when (and node (not (layout:locked? node)))
      (layout:select! window))))

(commands:define-command (mouse-delete-view [event (keys:command-event)])
  "Deletes the view whose status line was clicked, as layout:delete-view deletes the selected one, unless it is locked or layout:deletable? refuses its part."
  (unless (keys:event? event)
    (assertion-violation 'status-line:mouse-delete-view "not an event" event))
  (let* ([window (posn-view (keys:event-start event))] [node (and window (layout:view-node window))])
    (when (and node (not (layout:locked? node)) (layout:deletable? node))
      (layout:select! window)
      (layout:delete-view))))

(commands:define-command (mouse-reset-layout [event (keys:command-event)])
  "Selects the view whose status line was clicked and deletes the other views of its level, as layout:reset-layout does, unless it is locked."
  (unless (keys:event? event)
    (assertion-violation 'status-line:mouse-reset-layout "not an event" event))
  (let* ([window (posn-view (keys:event-start event))] [node (and window (layout:view-node window))])
    (when (and node (not (layout:locked? node)))
      (layout:select! window)
      (layout:reset-layout))))

(define (show-modified view)
  (check-view 'status-line:show-modified view)
  (let ([b (views:buffer view)])
    (and b (buffers:modified? b) "*")))

(define (show-buffer-name view)
  (check-view 'status-line:show-buffer-name view)
  (let ([b (views:buffer view)])
    (if b (buffers:name b) "")))

(define (show-position view)
  (check-view 'status-line:show-position view)
  (let ([describe (views:position-description)])
    (and describe (views:buffer view) (describe view))))

(define (show-percent-position view)
  (check-view 'status-line:show-percent-position view)
  (let ([b (views:buffer view)])
    (and b
         (let-values ([(lo hi) (views:bounds view)])
           (let* ([doc (buffers:document b)] [chars (document:unit characters)]
                  [start (document:offset doc lo chars)] [end (document:offset doc hi chars)]
                  [at (document:offset doc (views:point view) chars)])
             (cond
               [(>= at end) (if (<= at start) "All" "Bot")]
               [(<= at start) "Top"]
               ;; Rounded up and capped at 99, as Emacs's %p, so that 0%
               ;; and 100% never show: those places are Top and Bot.
               [else (format "~a%" (min 99 (ceiling (/ (* 100 (- at start)) (- end start)))))]))))))

(define (show-region-size view)
  (check-view 'status-line:show-region-size view)
  (let ([b (views:buffer view)])
    (and b
         (let* ([doc (buffers:document b)] [chars (document:unit characters)] [cursors (views:cursors view)]
                [regions (%merged-regions
                           (list-sort (lambda (x y) (< (car x) (car y)))
                             (fold-right
                               (lambda (c acc)
                                 (let ([p (views:cursor-point c)] [m (views:cursor-mark c)])
                                   (if (and m (not (= p m))) (cons (cons (min p m) (max p m)) acc) acc)))
                               '() cursors)))])
           (define (offset p) (document:offset doc p chars))
           ;; Counted as Emacs's count-lines: a region ending at a line's
           ;; start does not take in that line.
           (define (last-line e)
             (let ([line (document:line doc e)])
               (if (= (offset e) (offset (document:line-start doc line))) (- line 1) line)))
           (define (counted n one many) (format "~a ~a" n (if (= n 1) one many)))
           ;; As count-lines takes in no line after a final line break, a
           ;; region whose text ends with an atom's line break takes in none.
           (define (atom-counts s e)
             (let ([texts (buffers:atom-texts doc s e)])
               (let loop ([ts texts] [char-count 0] [line-count 0])
                 (if (null? ts)
                     (values char-count (- line-count (if (%ends-with-newline? (reverse texts) (offset e) offset) 1 0)))
                     (let ([t (cdar ts)])
                       (loop (cdr ts) (+ char-count (- (string-length t) 1))
                             (+ line-count (%newlines t))))))))
           ;; Cursors' regions can share a line; each line counts once.
           (let loop ([rs regions] [line-reach 0] [char-count 0] [line-count 0])
             (if (null? rs)
                 (and (pair? regions)
                      (let ([parts (append (list (counted char-count "character" "characters"))
                                           (if (> line-count 1) (list (counted line-count "line" "lines")) '())
                                           (if (pair? (cdr cursors)) (list (counted (length cursors) "cursor" "cursors")) '()))])
                        (fold-left (lambda (acc s) (string-append acc ", " s)) (car parts) (cdr parts))))
                 (let ([s (caar rs)] [e (cdar rs)])
                   (let ([from (document:line doc s)] [to (last-line e)])
                     (let-values ([(atom-chars atom-lines) (atom-counts s e)])
                       (loop (cdr rs) (max line-reach to)
                             (+ char-count (- (offset e) (offset s)) atom-chars)
                             (+ line-count (max 0 (+ (- to (max from (+ line-reach 1))) 1)) atom-lines)))))))))))

(define (%merged-regions sorted)
  (if (null? sorted)
      '()
      (let loop ([rs (cdr sorted)] [current (car sorted)] [acc '()])
        (cond
          [(null? rs) (reverse (cons current acc))]
          [(<= (caar rs) (cdr current)) (loop (cdr rs) (cons (car current) (max (cdr current) (cdar rs))) acc)]
          [else (loop (cdr rs) (car rs) (cons current acc))]))))

(define (%newlines s)
  (let loop ([i 0] [n 0])
    (if (= i (string-length s)) n (loop (+ i 1) (if (char=? (string-ref s i) #\newline) (+ n 1) n)))))

;; An atom with no text adds nothing, so the text ends with the atom
;; before it.
(define (%ends-with-newline? texts end offset)
  (and (pair? texts)
       (= (+ (offset (caar texts)) 1) end)
       (let ([t (cdar texts)])
         (if (string=? t "")
             (%ends-with-newline? (cdr texts) (- end 1) offset)
             (char=? (string-ref t (- (string-length t) 1)) #\newline)))))

(define (show-major-mode view)
  (check-view 'status-line:show-major-mode view)
  (let ([b (views:buffer view)])
    (and b (modes:lighter (modes:major-mode b)))))

(define (show-minor-modes view)
  (check-view 'status-line:show-minor-modes view)
  (let ([lighters (filter string? (map modes:lighter (modes:active-minor-modes view)))])
    (and (pair? lighters)
         (fold-left (lambda (acc s) (string-append acc " " s)) (car lighters) (cdr lighters)))))

(define-segment modified (show show-modified))
(define-segment buffer-name (show show-buffer-name))
(define-segment position (show show-position))
(define-segment percent-position (show show-percent-position))
(define-segment region-size (show show-region-size))
(define-segment major-mode (show show-major-mode))
(define-segment minor-modes (show show-minor-modes))

(define (%add-status-line draw-view-atom node view client)
  (let ([content (draw-view-atom node view client)])
    (if (and (layout:view-node view) (not (layout:locked? node)) (views:with-view view (visible)))
        (list content (draw view client))
        content)))

;; The line is rewritten before layout draws the clients, which it does after the
;; batch's end. Layout drops a deleted part's views at the batch's end,
;; so a status view can be seen to have lost its window only after it.
(define (%after-batch ended)
  (guard (c [#t (report c)])
    (as-module (this-module) (write-line!)))
  (ended)
  (guard (c [#t (report c)])
    (drop-status-views!)))

(table-set! segments modified (left 10))
(table-set! segments buffer-name (left 20))
(table-set! segments position (left 30))
(table-set! segments percent-position (left 40))
(table-set! segments region-size (left 50))
(table-set! segments major-mode (right 40))
(table-set! segments minor-modes (right 50))
(keys:bind! keymap "<mouse-1>" mouse-select-view)
(keys:bind! keymap "<mouse-2>" mouse-reset-layout)
(keys:bind! keymap "<mouse-3>" mouse-delete-view)
(keys:bind! keymap "<down-mouse-1>" keys:ignore)
(keys:bind! keymap "<drag-mouse-1>" keys:ignore)
(table-set! web:stylesheets 'status-line "status-line/status-line.css")
(advice-add! layout:draw-view-atom %add-status-line)
(advice-add! batch-ended %after-batch)
(add-hook! buffers:killed note-kill!)
(write-line!)
(on-unload
  (lambda ()
    (forget-windows! (lambda (w id) #f))
    (kill-status-buffer!)))
