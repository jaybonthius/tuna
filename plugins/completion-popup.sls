#!tuna
(import (completion) (ui) (buffers) (document) (views) (keys) (commands) (editing) (layout) (layout-float)
        (web) (haml) (undo))

(define-option rows 10 (lambda (v) (and (fixnum? v) (fx> v 0)))
  "How many rows a popup shows.")

(define-option auto-delay #f (lambda (v) (or (not v) (and (real? v) (>= v 0))))
  "Seconds after a command that inserts or deletes a character before completion at point starts by itself; #f never.")

(define-option auto-prefix 3 (lambda (v) (and (fixnum? v) (fx>= v 0)))
  "How many characters the completed text must hold before point for completion to start by itself.")

;; Point rests in the empty node while nothing is selected, since a
;; list's selected row is the row at point.
(define (%draw-nothing node view) '())

(buffers:define-kind %root (content nodes))

(buffers:define-kind %none (draw %draw-nothing))

(define-record-type %shown
  (sealed #t)
  (fields session buffer view (mutable popup-id) (mutable matches) (mutable widths)))

(define %popups '())

(define %count 0)

(define (%next-name)
  (set! %count (fx+ %count 1))
  (string-append " *Completion-popup-" (number->string %count) "*"))

(define (%popup-of s) (find (lambda (l) (eq? (%shown-session l) s)) %popups))

(define (%list-node b)
  (let ([doc (buffers:document b)] [found #f])
    (document:for-each-child (document:token doc 0) 1 (fx- (document:length doc) 1)
      (lambda (c at) (when (and (document:node? c) (eq? (document:node-kind c) 'ui:list)) (set! found c))))
    found))

(define (%empty-position b)
  (let ([doc (buffers:document b)] [found #f])
    (document:for-each-child (document:token doc 0) 1 (fx- (document:length doc) 1)
      (lambda (c at) (when (and (document:node? c) (not found) (eq? (document:node-kind c) 'completion-popup:%none))
                       (set! found (fx+ (document:node-start c) 1)))))
    found))

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

(define (%draw-row l matches k)
  (let* ([s (%shown-session l)] [m (vector-ref matches k)] [widths (%shown-widths l)])
    (haml
      (:div.completion-popup-row
        (:span.completion-popup-text (%mark (completion:text s m) (completion:spans s m)))
        (let loop ([cs (completion:annotation s m)] [ws widths] [acc '()])
          (if (null? cs)
              (reverse acc)
              (loop (cdr cs) (if (pair? ws) (cdr ws) '())
                    (cons (let ([c (car cs)] [w (and (pair? ws) (car ws))])
                            (haml (:span.completion-popup-column
                                    ([data-face (and (pair? c) (symbol->string (car c)))]
                                     [style (and w (string-append "min-inline-size:" (number->string w) "ch"))])
                                    (%column-text c))))
                          acc))))))))

(define (%choose l m)
  (let ([s (%shown-session l)])
    (completion:select! s m)
    (views:call-with-view (completion:session-view s) completion:exit)))

(define (%first-matches s)
  (let* ([matches (completion:session-matches s)] [n (fxmin (vector-length matches) (rows))])
    (let loop ([i 0] [acc '()])
      (if (fx= i n) (reverse acc) (loop (fx+ i 1) (cons (vector-ref matches i) acc))))))

(define (%widths s shown)
  (fold-left
    (lambda (widths m)
      (let loop ([cs (completion:annotation s m)] [ws widths] [acc '()])
        (cond
          [(null? cs) (append (reverse acc) ws)]
          [else (loop (cdr cs) (if (pair? ws) (cdr ws) '())
                      (cons (fxmax (string-length (%column-text (car cs))) (if (pair? ws) (car ws) 0)) acc))])))
    '()
    shown))

(define (%popup-width s shown)
  (fxmax 15 (fxmin 80 (fold-left (lambda (w m)
                                   (fxmax w (fold-left (lambda (n c) (fx+ n 1 (string-length (%column-text c))))
                                                       (string-length (completion:text s m))
                                                       (completion:annotation s m))))
                                 0 shown))))

(define (%indices n)
  (let ([v (make-vector n)])
    (do ([i 0 (fx+ i 1)]) ((fx= i n) v) (vector-set! v i i))))

(define (%index-of m matches)
  (let loop ([i 0])
    (and (fx< i (vector-length matches)) (if (eqv? (vector-ref matches i) m) i (loop (fx+ i 1))))))

;; The popup's view is dropped once layout-float removes it, as when the
;; completed text's view goes, so it is kept by number.
(define (%close-popup! l)
  (let* ([id (%shown-popup-id l)] [v (and id (views:find id))])
    (%shown-popup-id-set! l #f)
    (when (and v (layout:popup-node v))
      (layout-float:close! v))))

(define (%show! l)
  (let* ([s (%shown-session l)] [b (%shown-buffer l)] [v (%shown-view l)]
         [matches (completion:session-matches s)] [m (completion:selected s)])
    (unless (eq? matches (%shown-matches l))
      (let ([shown (%first-matches s)])
        (%shown-matches-set! l matches)
        (%shown-widths-set! l (%widths s shown))
        (ui:set-rows! b (%list-node b) (%indices (vector-length matches))
                      (lambda (k) (%draw-row l matches k))
                      (lambda (k) (%choose l (vector-ref matches k)))
                      (rows))
        (if (fx= (vector-length matches) 0)
            (%close-popup! l)
            (as-module (this-module)
              (%shown-popup-id-set! l
                (views:id
                  (layout-float:show-at! (completion:session-view s) (completion:session-start s) b
                                         (list 'columns (%popup-width s shown))
                                         (list 'lines (fxmax 1 (length shown))))))))))
    (let ([k (and m (%index-of m matches))])
      (if k
          (ui:select-row! (%list-node b) v k)
          (views:set-point! v (%empty-position b))))))

;; A prompt sits in a locked part and a field may be drawn inside another
;; buffer; only a view the user edits in, an unlocked part of the layout,
;; has a place for a popup at point.
(define (%started s)
  (let* ([view (completion:session-view s)] [node (layout:view-node view)])
    (when (and node (not (layout:locked? node)))
      (let* ([b (buffers:make (%next-name) (%root '() (%none '()) (ui:list '())))]
             [l (make-%shown s b (views:make b) #f #f '())])
        (buffers:with-buffer b (set-option-local! undo:limit 0))
        (set! %popups (cons l %popups))))))

(define (%updated s)
  (let ([l (%popup-of s)])
    (when l (%show! l))))

(define (%ended s)
  (let ([l (%popup-of s)])
    (when l
      (set! %popups (remq l %popups))
      (%close-popup! l)
      (views:drop! (%shown-view l))
      (buffers:kill! (%shown-buffer l)))))

(define %timer #f)

(define (%auto-commands)
  (list editing:self-insert editing:delete-backward-char editing:delete-char))

(define (%maybe-start command)
  (when %timer
    (cancel-timer! %timer)
    (set! %timer #f))
  (let ([view (views:current)] [client (web:current-client)])
    (when (and view client (memq command (%auto-commands)) (not (completion:current-session)))
      (let ([delay (auto-delay)] [minimum (auto-prefix)] [id (views:id view)])
        (when delay
          (as-module (this-module)
            (set! %timer
              (run-with-timer delay
                (lambda ()
                  (set! %timer #f)
                  (when (and (views:find id) (views:buffer view))
                    (views:call-with-view view
                      (lambda ()
                        (parameterize ([web:current-client client])
                          (completion:start-at-point client minimum))))))))))))))

(define (%unload)
  (when %timer (cancel-timer! %timer))
  (for-each (lambda (l) (%ended (%shown-session l))) %popups))

(keys:remap! completion:region-keymap editing:next-line completion:next)
(keys:remap! completion:region-keymap editing:previous-line completion:previous)
(keys:remap! completion:region-keymap editing:beginning-of-buffer completion:first)
(keys:remap! completion:region-keymap editing:end-of-buffer completion:last)
(keys:bind! completion:region-keymap "M-n" completion:next)
(keys:bind! completion:region-keymap "M-p" completion:previous)
(table-set! web:stylesheets 'completion-popup "completion-popup/completion-popup.css")
(add-hook! completion:started %started)
(add-hook! completion:updated %updated)
(add-hook! completion:ended %ended)
(add-hook! commands:after-command %maybe-start)
(on-unload %unload)
