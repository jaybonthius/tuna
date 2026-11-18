#!tuna
(import (completion) (minibuffer) (ui) (buffers) (document) (views) (keys) (editing) (faces) (web) (haml))

(define-option rows 10 (lambda (v) (and (fixnum? v) (fx> v 0)))
  "How many rows a read's list shows.")

(define-option fixed-height? #f boolean?
  "When true, a read's list is completion-list:rows tall from its first draw; otherwise it grows as rows arrive and keeps its height until the read ends.")

;; Point rests in the empty node while nothing is selected, since a
;; list's selected row is the row at point.
(define (%draw-nothing node view) '())

(define (%draw-count node view) (%counts view))

(define (%draw-root node view)
  (let ([l (%list-of-view view)])
    (haml (:div.completion-list ([style (string-append "--completion-list-rows:"
                                          (number->string (if (or (fixed-height?) (not l)) (rows) (%shown-height l))))])
            (views:draw-children view node)))))

(buffers:define-kind %root (content nodes) (draw %draw-root))

(buffers:define-kind %none (draw %draw-nothing))

(buffers:define-kind %count-line (content atom) (draw %draw-count))

(define-record-type %shown
  (sealed #t)
  (fields session buffer view (mutable matches) (mutable widths) prompt (mutable height)))

(define %lists '())

(define %count 0)

(define (%next-name)
  (set! %count (fx+ %count 1))
  (string-append " *Completions-" (number->string %count) "*"))

(define (%list-of s) (find (lambda (l) (eq? (%shown-session l) s)) %lists))

(define (%list-of-view view) (find (lambda (l) (eq? (%shown-view l) view)) %lists))

(define (%list-node b)
  (let ([doc (buffers:document b)] [found #f])
    (document:for-each-child (document:token doc 0) 1 (fx- (document:length doc) 1)
      (lambda (c at) (when (and (document:node? c) (eq? (document:node-kind c) 'ui:list)) (set! found c))))
    found))

(define (%empty-position b)
  (let ([doc (buffers:document b)] [found #f])
    (document:for-each-child (document:token doc 0) 1 (fx- (document:length doc) 1)
      (lambda (c at) (when (and (document:node? c) (not found) (eq? (document:node-kind c) 'completion-list:%none))
                       (set! found (fx+ (document:node-start c) 1)))))
    found))

(define (%index-of m matches)
  (let loop ([i 0])
    (and (fx< i (vector-length matches)) (if (eqv? (vector-ref matches i) m) i (loop (fx+ i 1))))))

(define (%counts view)
  (let ([l (%list-of-view view)])
    (if l
        (let* ([s (%shown-session l)] [matches (completion:session-matches s)] [m (completion:selected s)]
               [k (and m (%index-of m matches))])
          (haml (:div.completion-list-count ([data-face (symbol->string faces:shadow)])
                  (if k (fx+ k 1) 0) "/" (vector-length matches)
                  (when (completion:session-busy? s) " …"))))
        '())))

(define (%mark text spans)
  (let loop ([at 0] [spans spans] [acc '()])
    (cond
      [(null? spans) (reverse (if (fx< at (string-length text)) (cons (substring text at (string-length text)) acc) acc))]
      [else
       (let ([s (fxmax at (caar spans))] [e (fxmin (string-length text) (cdar spans))])
         (if (fx< s e)
             (loop e (cdr spans)
                   (cons (haml (:mark (substring text s e)))
                         (if (fx< at s) (cons (substring text at s) acc) acc)))
             (loop at (cdr spans) acc)))])))

(define (%column-text c) (if (pair? c) (cdr c) c))

(define (%draw-column c width)
  (haml (:span.completion-list-column ([data-face (and (pair? c) (symbol->string (car c)))]
                                       [style (and width (string-append "--completion-list-column-size:" (number->string width) "ch"))])
          (%column-text c))))

(define (%title-first? s matches k title)
  (and title (or (fx= k 0) (not (equal? title (completion:title s (vector-ref matches (fx- k 1))))))))

;; A row is a match's place in the matches, so drawing it can tell the
;; first match of a titled source without walking every match.
(define (%draw-row l matches k)
  (let* ([s (%shown-session l)] [m (vector-ref matches k)] [text (completion:text s m)] [title (completion:title s m)]
         [columns (completion:annotation s m)] [widths (%shown-widths l)])
    ;; The title sits outside the row, which clips everything after its
    ;; first line.
    (list
      (if (%title-first? s matches k title) (haml (:div.completion-list-title title)) '())
      (haml
        (:div.completion-list-row
          (:span.completion-list-text (%mark text (completion:spans s m)))
          (let loop ([cs columns] [ws widths] [acc '()])
            (if (null? cs)
                (reverse acc)
                (loop (cdr cs) (if (pair? ws) (cdr ws) '())
                      (cons (%draw-column (car cs) (and (pair? ws) (car ws))) acc)))))))))

(define (%choose l m)
  (let ([s (%shown-session l)])
    (completion:select! s m)
    (views:call-with-view (completion:session-view s) completion:exit)))

(define (%shown-matches-of l)
  (let* ([s (%shown-session l)] [matches (completion:session-matches s)]
         [n (fxmin (vector-length matches) (rows))])
    (let loop ([i 0] [acc '()])
      (if (fx= i n) (reverse acc) (loop (fx+ i 1) (cons (vector-ref matches i) acc))))))

(define (%widths l shown)
  (let ([s (%shown-session l)])
    (fold-left
      (lambda (widths m)
        (let loop ([cs (completion:annotation s m)] [ws widths] [acc '()])
          (cond
            [(null? cs) (append (reverse acc) ws)]
            [else (loop (cdr cs) (if (pair? ws) (cdr ws) '())
                        (cons (fxmax (string-length (%column-text (car cs))) (if (pair? ws) (car ws) 0)) acc))])))
      '()
      shown)))

(define (%indices n)
  (let ([v (make-vector n)])
    (do ([i 0 (fx+ i 1)]) ((fx= i n) v) (vector-set! v i i))))

(define (%show! l)
  (let* ([s (%shown-session l)] [b (%shown-buffer l)] [v (%shown-view l)]
         [matches (completion:session-matches s)] [m (completion:selected s)])
    (unless (eq? matches (%shown-matches l))
      (let ([shown (%shown-matches-of l)])
        (%shown-matches-set! l matches)
        (%shown-widths-set! l (%widths l shown))
        (ui:set-rows! b (%list-node b) (%indices (vector-length matches))
                      (lambda (k) (%draw-row l matches k))
                      (lambda (k) (%choose l (vector-ref matches k)))
                      (rows))))
    (let ([k (and m (%index-of m matches))])
      (if k
          (ui:select-row! (%list-node b) v k)
          (views:set-point! v (%empty-position b))))))

;; A session over a prompt's input is a read; the others are left to a
;; display for completion at point.
(define (%started s)
  (when (minibuffer:buffer? (views:buffer (completion:session-view s)))
    (let* ([b (buffers:make (%next-name) (%root '() (%count-line '()) (%none '()) (ui:list '())))]
           [v (views:make b)]
           [l (make-%shown s b v #f '() (minibuffer:current-prompt) 0)])
      (set! %lists (cons l %lists))
      (let ([p (%shown-prompt l)])
        (when p
          (minibuffer:set-content! p (list (views:view (list (cons 'view (views:id v)) (cons 'buffer (buffers:name b)))))))))))

(define (%updated s)
  (let ([l (%list-of s)])
    (when l (%show! l))))

(define (%ended s)
  (let ([l (%list-of s)])
    (when l
      (set! %lists (remq l %lists))
      (views:drop! (%shown-view l))
      (buffers:kill! (%shown-buffer l)))))

;; The list never shrinks during a read, so the input above it does not
;; jump back and forth as the matches change. Its height is taken when a
;; batch ends, not at each match round: a read's first round, before a
;; setup gives the input, may match every candidate.
(define (%note-heights ended)
  (guard (c [#t (report c)])
    (for-each
      (lambda (l)
        (%shown-height-set! l (fxmax (%shown-height l)
                                     (fxmin (vector-length (completion:session-matches (%shown-session l))) (rows)))))
      %lists))
  (ended))

;; A running session's prompt is waiting, so its content can be cleared.
(define (%unload)
  (for-each
    (lambda (l)
      (let ([p (%shown-prompt l)])
        (when p (minibuffer:set-content! p '())))
      (%ended (%shown-session l)))
    %lists))

(keys:remap! completion:keymap editing:next-line completion:next)
(keys:remap! completion:keymap editing:previous-line completion:previous)
(keys:remap! completion:keymap editing:beginning-of-buffer completion:first)
(keys:remap! completion:keymap editing:end-of-buffer completion:last)
(table-set! web:stylesheets 'completion-list "completion-list/completion-list.css")
(add-hook! completion:started %started)
(add-hook! completion:updated %updated)
(add-hook! completion:ended %ended)
(advice-add! batch-ended %note-heights)
(on-unload %unload)
