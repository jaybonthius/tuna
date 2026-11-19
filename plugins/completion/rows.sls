#!tuna
(import (completion) (ui) (buffers) (document) (views) (web) (haml))

;; Point rests before an atom that draws nothing while nothing is
;; selected, since a list's selected row is the row at point: the start
;; of an atom is a stop of its own, where the inside of an empty node is
;; one place with the first row's.
(define (%draw-nothing node view) '())

(buffers:define-kind %none (content atom) (draw %draw-nothing))

(define %none-kind (buffers:kind-name (buffers:constructor-kind %none)))

(define %list-kind (buffers:kind-name (buffers:constructor-kind ui:list)))

(define-record-type %rows
  (sealed #t)
  (fields session buffer most (mutable matches) (mutable count) (mutable widths)))

(define %made 0)

(define (%next-name)
  (set! %made (fx+ %made 1))
  (string-append " *Completions-" (number->string %made) "*"))

(define (%check who r)
  (unless (%rows? r)
    (assertion-violation who "not rows" r)))

(define (make session most root)
  (unless (completion:session? session)
    (assertion-violation 'completion/rows:make "not a session" session))
  (unless (procedure? most)
    (assertion-violation 'completion/rows:make "not a procedure" most))
  (unless (procedure? root)
    (assertion-violation 'completion/rows:make "not a procedure" root))
  (let ([b (buffers:make (%next-name) (root (list (%none '()) (ui:list '()))))])
    (buffers:with-buffer b (set-option-local! views:cursor-visible #f))
    (make-%rows session b most #f 0 '())))

(define (rows? v) (%rows? v))

(define (session r) (%check 'completion/rows:session r) (%rows-session r))

(define (buffer r) (%check 'completion/rows:buffer r) (%rows-buffer r))

(define (%list-node b)
  (let ([doc (buffers:document b)] [found #f])
    (document:for-each-child (document:token doc 0) 1 (fx- (document:length doc) 1)
      (lambda (c at) (when (and (document:node? c) (eq? (document:node-kind c) %list-kind)) (set! found c))))
    found))

(define (%empty-position b)
  (let ([doc (buffers:document b)] [found #f])
    (document:for-each-child (document:token doc 0) 1 (fx- (document:length doc) 1)
      (lambda (c at) (when (and (document:node? c) (not found) (eq? (document:node-kind c) %none-kind))
                       (set! found (document:node-start c)))))
    found))

(define (%mark text spans)
  (let loop ([at 0] [spans spans] [acc '()])
    (cond
      [(null? spans) (reverse (if (fx< at (string-length text)) (cons (substring text at (string-length text)) acc) acc))]
      [else
       (let* ([span (car spans)] [s (fxmax at (car span))] [e (fxmin (string-length text) (cadr span))]
              [face (caddr span)])
         (if (fx< s e)
             (loop e (cdr spans)
                   (cons (haml (:mark ([data-face (and face (symbol->string face))]) (substring text s e)))
                         (if (fx< at s) (cons (substring text at s) acc) acc)))
             (loop at (cdr spans) acc)))])))

(define (%column-text c) (if (pair? c) (cdr c) c))

(define (%draw-column c width)
  (haml (:span.completion-column ([data-face (and (pair? c) (symbol->string (car c)))]
                                  [style (and width (string-append "--completion-column-size:" (number->string width) "ch"))])
          (%column-text c))))

(define (%title-first? s matches k title)
  (and title (or (fx= k 0) (not (equal? title (completion:title s (completion:matches-ref matches (fx- k 1))))))))

;; A row is a match's place in the matches, so drawing it can tell the
;; first match of a titled source without walking every match.
(define (%draw-row r matches k)
  (let* ([s (%rows-session r)] [m (completion:matches-ref matches k)] [text (completion:text s m)]
         [title (completion:title s m)] [columns (completion:annotation s m)] [widths (%rows-widths r)])
    ;; The title sits outside the row, which clips everything after its
    ;; first line.
    (list
      (if (%title-first? s matches k title) (haml (:div.completion-title title)) '())
      (haml
        (:div.completion-row
          (:span.completion-text (%mark text (completion:spans s m)))
          (let loop ([cs columns] [ws widths] [acc '()])
            (if (null? cs)
                (reverse acc)
                (loop (cdr cs) (if (pair? ws) (cdr ws) '())
                      (cons (%draw-column (car cs) (and (pair? ws) (car ws))) acc)))))))))

(define (%choose r m)
  (let ([s (%rows-session r)])
    (completion:select! s m)
    (views:call-with-view (completion:session-view s) completion:exit)))

(define (%shown r)
  (let* ([matches (completion:session-matches (%rows-session r))]
         [n (fxmin (completion:matches-count matches) ((%rows-most r)))])
    (let loop ([i 0] [acc '()])
      (if (fx= i n) (reverse acc) (loop (fx+ i 1) (cons (completion:matches-ref matches i) acc))))))

(define (%widths r shown)
  (let ([s (%rows-session r)])
    (fold-left
      (lambda (widths m)
        (let loop ([cs (completion:annotation s m)] [ws widths] [acc '()])
          (cond
            [(null? cs) (append (reverse acc) ws)]
            [else (loop (cdr cs) (if (pair? ws) (cdr ws) '())
                        (cons (fxmax (string-length (%column-text (car cs))) (if (pair? ws) (car ws) 0)) acc))])))
      '()
      shown)))

(define (%indices from to)
  (let ([v (make-vector (fx- to from))])
    (do ([i from (fx+ i 1)]) ((fx= i to) v) (vector-set! v (fx- i from) i))))

;; A list's selected row is the row at a view's point, and each view has
;; its own, so every view a display places of the rows follows.
(define (follow-selection! r)
  (%check 'completion/rows:follow-selection! r)
  (let* ([s (%rows-session r)] [b (%rows-buffer r)] [m (completion:selected s)]
         [k (and m (completion:matches-index (completion:session-matches s) m))])
    (for-each
      (lambda (v)
        (if k
            (ui:select-row! (%list-node b) v k)
            (views:set-point! v (%empty-position b))))
      (views:showing b))))

;; A stream's matches grow at their end, thousands of times, so only the
;; rows they add are given to the list once it shows as many as it can:
;; the columns' widths are those of the rows shown.
(define (update! r)
  (%check 'completion/rows:update! r)
  (let* ([s (%rows-session r)] [b (%rows-buffer r)] [most ((%rows-most r))]
         [matches (completion:session-matches s)] [n (completion:matches-count matches)]
         [afresh? (or (not (eq? matches (%rows-matches r))) (and (fx< (%rows-count r) most) (fx> n (%rows-count r))))])
    (cond
      [afresh?
       (%rows-matches-set! r matches)
       (%rows-count-set! r n)
       (%rows-widths-set! r (%widths r (%shown r)))
       (ui:set-rows! b (%list-node b) (%indices 0 n)
                     (lambda (k) (%draw-row r matches k))
                     (lambda (k) (%choose r (completion:matches-ref matches k)))
                     most)]
      [(fx> n (%rows-count r))
       (ui:add-rows! b (%list-node b) (%indices (%rows-count r) n))
       (%rows-count-set! r n)])
    (follow-selection! r)
    afresh?))

(define (width r)
  (%check 'completion/rows:width r)
  (let ([s (%rows-session r)])
    (fold-left (lambda (w column) (fx+ w 1 column))
               (fold-left (lambda (w m) (fxmax w (string-length (completion:text s m)))) 0 (%shown r))
               (%rows-widths r))))

(define (lines r)
  (%check 'completion/rows:lines r)
  (let* ([s (%rows-session r)] [matches (completion:session-matches s)] [shown (length (%shown r))])
    (let loop ([k 0] [titles 0])
      (if (fx= k shown)
          (fx+ shown titles)
          (loop (fx+ k 1)
                (if (%title-first? s matches k (completion:title s (completion:matches-ref matches k))) (fx+ titles 1) titles))))))

(define (drop! r)
  (%check 'completion/rows:drop! r)
  (buffers:kill! (%rows-buffer r)))

;; The path is relative to this module's own folder, completion/.
(table-set! web:stylesheets 'completion-rows "rows.css")
