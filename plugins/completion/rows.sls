#!tuna
(import (completion) (ui) (buffers) (document) (views) (commands) (modes) (web) (haml))

;; Point rests before an atom that draws nothing while nothing is
;; selected, since a list's selected row is the row at point: the start
;; of an atom is a stop of its own, where the inside of an empty node is
;; one place with the first row's.
(define (%draw-nothing node view) '())

(buffers:define-kind %none (content atom) (draw %draw-nothing))

(define %none-kind (buffers:kind-name (buffers:constructor-kind %none)))

(define %list-kind (buffers:kind-name (buffers:constructor-kind ui:list)))

(define-table mode-keymap
  "Keys in the rows' buffers. Their views are never selected, so keys reach them only as mouse keys, which ui:list-keys binds.")

(define-hook mode-hook
  "Called with a rows' buffer current when its mode is set, before the hook of the display's own mode.")

(modes:define-major-mode mode (lighter "Completions") (keymap mode-keymap) (hook mode-hook))

;; Only the session moves a rows' view's point, so a hand scroll must leave
;; it, or the row drawn as selected would not be the one RET chooses.
(define (%rows-settings)
  (set-option-local! views:scroll-margin 2)
  (set-option-local! views:cursor-visible #f)
  (set-option-local! views:hand-scroll-moves-point #f))

;; The widths are of the rows drawn in the session, and only grow, so a
;; screen's columns line up and nothing jitters as the rows scroll.
(define-record-type %rows
  (sealed #t)
  (fields session buffer most (mutable matches) (mutable count) (mutable widths) (mutable text-width)))

(define %made 0)

(define %all '())

(define (%next-name)
  (set! %made (fx+ %made 1))
  (string-append " *Completions-" (number->string %made) "*"))

(define (%check who r)
  (unless (%rows? r)
    (assertion-violation who "not rows" r)))

(define (%rows-of b) (find (lambda (r) (eq? (%rows-buffer r) b)) %all))

;; The widths are written after the rows are drawn, since drawing them is
;; what measures them.
(define (%draw-rows node view)
  (let* ([r (%rows-of (views:buffer view))] [children (views:draw-children view node)])
    (haml (:div.completion-rows ([style (and r (%widths-style r))]) children))))

(buffers:define-kind %frame (content nodes) (draw %draw-rows))

(define make
  (case-lambda
    [(session most root) (make session most root mode)]
    [(session most root display-mode)
     (unless (completion:session? session)
       (assertion-violation 'completion/rows:make "not a session" session))
     (unless (procedure? most)
       (assertion-violation 'completion/rows:make "not a procedure" most))
     (unless (procedure? root)
       (assertion-violation 'completion/rows:make "not a procedure" root))
     (unless (and (symbol? display-mode) (modes:derived? display-mode mode))
       (assertion-violation 'completion/rows:make "not a mode derived from completion/rows:mode" display-mode))
     (let ([b (buffers:make (%next-name) (root (list (%none '()) (%frame '() (ui:list '())))))])
       (modes:set-major-mode display-mode b)
       (let ([r (make-%rows session b most #f 0 '() 0)])
         (set! %all (cons r %all))
         r))]))

(define (rows? v) (%rows? v))

(define (session r) (%check 'completion/rows:session r) (%rows-session r))

(define (buffer r) (%check 'completion/rows:buffer r) (%rows-buffer r))

(define (%list-node b)
  (let ([doc (buffers:document b)])
    (let loop ([p 0])
      (let ([t (document:token doc p)])
        (if (and (document:node? t) (eq? (document:node-kind t) %list-kind))
            t
            (loop (fx+ p 1)))))))

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

(define (%draw-column c k)
  (haml (:span.completion-column ([data-face (and (pair? c) (symbol->string (car c)))]
                                  [style (string-append "--completion-column-size:var(--completion-column-"
                                                        (number->string k) "-size)")])
          (%column-text c))))

(define (%grow-widths! r text columns)
  (%rows-text-width-set! r (fxmax (%rows-text-width r) (string-length text)))
  (%rows-widths-set! r
    (let loop ([cs columns] [ws (%rows-widths r)] [acc '()])
      (cond
        [(null? cs) (append (reverse acc) ws)]
        [else (loop (cdr cs) (if (pair? ws) (cdr ws) '())
                    (cons (fxmax (string-length (%column-text (car cs))) (if (pair? ws) (car ws) 0)) acc))]))))

(define (%widths-style r)
  (let loop ([ws (%rows-widths r)] [k 1] [total (%rows-text-width r)] [acc '()])
    (if (null? ws)
        (apply string-append
          (reverse (cons (string-append "--completion-rows-width:" (number->string total) "ch") acc)))
        (loop (cdr ws) (fx+ k 1) (fx+ total 1 (car ws))
              (cons (string-append "--completion-column-" (number->string k) "-size:" (number->string (car ws)) "ch;")
                    acc)))))

(define (%draw-row r matches k)
  (let* ([s (%rows-session r)] [m (completion:matches-ref matches k)] [text (completion:row-text s m)]
         [columns (completion:annotation s m)])
    (%grow-widths! r text columns)
    (haml
      (:div.completion-row
        (:span.completion-text (%mark text (completion:spans s m)))
        (let loop ([cs columns] [k 1] [acc '()])
          (if (null? cs)
              (reverse acc)
              (loop (cdr cs) (fx+ k 1) (cons (%draw-column (car cs) k) acc))))))))

(define (%choose r m)
  (let ([s (%rows-session r)])
    (completion:select! s m)
    (views:call-with-view (completion:session-view s) completion:exit)))

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

;; A stream's round, which runs no command, leaves a view scrolled by hand
;; where it is; new matches, and every command that updates the session,
;; show the selection.
(define (update! r)
  (%check 'completion/rows:update! r)
  (let* ([s (%rows-session r)] [b (%rows-buffer r)]
         [matches (completion:session-matches s)] [n (completion:matches-count matches)]
         [afresh? (not (eq? matches (%rows-matches r)))])
    (cond
      [afresh?
       (%rows-matches-set! r matches)
       (%rows-count-set! r n)
       (ui:set-rows! b (%list-node b) n
                     (lambda (k) (%draw-row r matches k))
                     (lambda (k) (%choose r (completion:matches-ref matches k)))
                     (lambda (k) (completion:title s (completion:matches-ref matches k))))]
      [(fx> n (%rows-count r))
       (ui:add-rows! b (%list-node b) (fx- n (%rows-count r)))
       (%rows-count-set! r n)])
    (when (or afresh? (commands:this-command))
      (follow-selection! r))
    afresh?))

(define (lines r)
  (%check 'completion/rows:lines r)
  (let ([b (%rows-buffer r)])
    (ui:list-lines b (%list-node b) ((%rows-most r)))))

(define (drop! r)
  (%check 'completion/rows:drop! r)
  (set! %all (remq r %all))
  (buffers:kill! (%rows-buffer r)))

;; A page is as many rows as the session's rows show, which only the
;; plugin that shows them knows, so the page moves are here.
(define (%move-page who pages)
  (let* ([s (or (completion:current-session) (assertion-violation who "no completion session in the selected view"))]
         [r (find (lambda (r) (eq? (%rows-session r) s)) %all)] [matches (completion:session-matches s)]
         [n (completion:matches-count matches)] [m (completion:selected s)]
         [k (or (and m (completion:matches-index matches m)) -1)])
    (when (and r (fx> n 0))
      (completion:select! s (completion:matches-ref matches (fxmax 0 (fxmin (fx- n 1) (fx+ k (fx* pages ((%rows-most r)))))))))))

(commands:define-command (scroll-up [n (commands:prefix-number)])
  "Selects the match N pages of rows after the selected one, stopping at the last."
  (%move-page 'completion/rows:scroll-up n))

(commands:define-command (scroll-down [n (commands:prefix-number)])
  "Selects the match N pages of rows before the selected one, stopping at the first."
  (%move-page 'completion/rows:scroll-down (fx- 0 n)))

;; The path is relative to this module's own folder, completion/.
(table-set! web:stylesheets 'completion-rows "rows.css")
(add-hook! mode-hook %rows-settings)
