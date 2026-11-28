#!tuna
(import (buffers) (document) (views) (layout) (keys) (commands) (modes) (web) (haml) (options) (tables))

(options:define-option visible #t boolean? "Whether a view has a status line.")

(tables:define-table segments
  "Where segments show: each segment's place, from status-line:left or status-line:right.")

(tables:define-table keymap "The keymap of the status line, searched after its segments' keymaps.")

;; Tables, so unloading the module that defines a segment takes back its
;; show procedure and keymap.
(tables:define-table %shows)

(tables:define-table %keymaps)

(module %internals
  (check-main-thread check-view make-place place-record? placed-segments segment-html exported-name)

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

  (define (exported-name owner id)
    (if (member owner '((init) (repl)))
        id
        (string->symbol (format "~{~a~^/~}:~a" owner id))))

  ;; A show procedure that raises is reported once for its window, until
  ;; it shows again without raising, rather than at every draw.
  (define failing (make-weak-eq-hashtable))

  (define (show-failed! name window c)
    (let ([names (eq-hashtable-ref failing window '())])
      (unless (memq name names)
        (eq-hashtable-set! failing window (cons name names))
        (report c)))
    #f)

  (define (shown-html name show window)
    (guard (c [(not (cancelled? c)) (show-failed! name window c)])
      (let ([r (views:with-view window (show window))])
        (cond
          [(or (not r) (string? r) (html? r))
           (let ([names (eq-hashtable-ref failing window '())])
             (when (memq name names)
               (eq-hashtable-set! failing window (remq name names))))
           r]
          [else
           (show-failed! name window
             (condition (make-assertion-violation) (make-who-condition name)
               (make-message-condition "a show procedure returned what is not HTML, a string or #f")
               (make-irritants-condition (list r))))]))))

  (define (segment-html name window)
    (let ([content (or (shown-html name (tables:ref %shows name #f) window) (list))]
          [keymap (tables:ref %keymaps name #f)])
      (if keymap
          (haml (:button.status-line-segment ([type "button"] [tabindex "-1"] [data-segment (symbol->string name)]
                                              [data-keymap (views:keymap-mark keymap)])
                  content))
          (haml (:span.status-line-segment ([data-segment (symbol->string name)]) content)))))

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

  ;; Equal numbers keep the order of tables:entries, the order first
  ;; placed, since list-sort is stable.
  (define (placed side entries)
    (map car
      (list-sort (lambda (a b) (< (place-n (cdr a)) (place-n (cdr b))))
                 (filter (lambda (e) (eq? (place-side (cdr e)) side)) entries))))

  (define (placed-segments)
    (let-values ([(entries bad) (partition (lambda (e) (place-record? (cdr e)))
                                           (filter (lambda (e) (tables:ref %shows (car e) #f)) (tables:entries segments)))])
      (report-misplaced! bad)
      (values (placed 'left entries) (placed 'right entries)))))

(import %internals)

(define (%define-segment! id show keymap)
  (unless (procedure? show)
    (assertion-violation 'status-line:define-segment "not a procedure" show))
  (unless (or (not keymap) (tables:table? keymap))
    (assertion-violation 'status-line:define-segment "not a keymap or #f" keymap))
  (let ([name (exported-name (owner-name (current-owner)) id)])
    (tables:set! %shows name show)
    (if keymap (tables:set! %keymaps name keymap) (tables:remove! %keymaps name))
    name))

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
               #`(define-public id (%define-segment! 'id #,show #,keymap)))
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

(define (draw view client)
  (check-view 'status-line:draw view)
  (unless (or (not client) (web:client? client))
    (assertion-violation 'status-line:draw "not a client or #f" client))
  (check-main-thread 'status-line:draw)
  (and (layout:view-node view)
       (let-values ([(left right) (placed-segments)])
         (haml (:footer.status-line ([data-keymap (views:keymap-mark keymap)])
                 (map (lambda (name) (segment-html name view)) left)
                 (:div.status-line-right (map (lambda (name) (segment-html name view)) right)))))))

(define (%clicked-window who event)
  (unless (keys:event? event)
    (assertion-violation who "not an event" event))
  (let* ([posn (keys:event-start event)] [v (views:posn-view posn)] [node (views:posn-node posn)])
    (and v node (eq? (views:buffer v) layout:buffer) (layout:part-view node))))

(commands:define-command (mouse-delete-view [event (keys:command-event)])
  "Deletes the view whose status line was clicked, as layout:delete-view deletes the selected one, unless it is locked or layout:deletion-refusal refuses its part."
  (let* ([window (%clicked-window 'status-line:mouse-delete-view event)] [node (and window (layout:view-node window))])
    (when (and node (not (layout:locked? node)) (not (layout:deletion-refusal node)))
      (layout:select! window)
      (layout:delete-view))))

(commands:define-command (mouse-reset-layout [event (keys:command-event)])
  "Selects the view whose status line was clicked and deletes the other views of its level, as layout:reset-layout does, unless it is locked."
  (let* ([window (%clicked-window 'status-line:mouse-reset-layout event)] [node (and window (layout:view-node window))])
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
                [regions (views:region-bounds view)])
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
           ;; The ranges can share a line; each line counts once.
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

(tables:set! segments modified (left 10))
(tables:set! segments buffer-name (left 20))
(tables:set! segments position (left 30))
(tables:set! segments percent-position (left 40))
(tables:set! segments region-size (left 50))
(tables:set! segments major-mode (right 40))
(tables:set! segments minor-modes (right 50))
(keys:bind! keymap "<mouse-2>" mouse-reset-layout)
(keys:bind! keymap "<mouse-3>" mouse-delete-view)
(keys:bind! keymap "<down-mouse-1>" keys:ignore)
(keys:bind! keymap "<drag-mouse-1>" keys:ignore)
(tables:set! web:stylesheets 'status-line "status-line/status-line.css")
(advice-add! layout:draw-view-atom %add-status-line)
