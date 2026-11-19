#!tuna
(import (completion) (ui) (buffers) (document) (views) (keys) (commands) (editing) (layout) (layout-float)
        (web) (haml))

(define-option rows 10 (lambda (v) (and (fixnum? v) (fx> v 0)))
  "How many rows a popup shows.")

(define-option auto-delay #f (lambda (v) (or (not v) (and (real? v) (>= v 0))))
  "Seconds after a command that inserts or deletes a character before completion at point starts by itself; #f never.")

(define-option auto-prefix 3 (lambda (v) (and (fixnum? v) (fx>= v 0)))
  "How many characters the completed text must hold before point for completion to start by itself.")

(define (%draw-nothing node view) '())

(buffers:define-kind %root (content nodes))

;; Point rests on this atom while nothing is selected, since a list's
;; selected row is the row at point. An empty node would not do: with no
;; text between them, its inside and the first row are one place, and
;; point goes to the row.
(buffers:define-kind %none (content atom) (draw %draw-nothing))

(define-record-type %shown
  (sealed #t)
  (fields session buffer (mutable popup-id) (mutable matches) (mutable count) (mutable widths)))

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

(define (%draw-row l matches k)
  (let* ([s (%shown-session l)] [m (completion:matches-ref matches k)] [widths (%shown-widths l)])
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
  (let* ([matches (completion:session-matches s)] [n (fxmin (completion:matches-count matches) (rows))])
    (let loop ([i 0] [acc '()])
      (if (fx= i n) (reverse acc) (loop (fx+ i 1) (cons (completion:matches-ref matches i) acc))))))

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

(define (%indices from to)
  (let ([v (make-vector (fx- to from))])
    (do ([i from (fx+ i 1)]) ((fx= i to) v) (vector-set! v (fx- i from) i))))

(define (%index-of m matches)
  (let ([n (completion:matches-count matches)])
    (let loop ([i 0])
      (and (fx< i n) (if (eqv? (completion:matches-ref matches i) m) i (loop (fx+ i 1)))))))

;; The popup's view is dropped once layout-float removes it, as when the
;; completed text's view goes, so it is kept by number.
(define (%popup-view l)
  (let ([id (%shown-popup-id l)]) (and id (views:find id))))

(define (%close-popup! l)
  (let ([v (%popup-view l)])
    (%shown-popup-id-set! l #f)
    (when (and v (layout:popup-node v))
      (layout-float:close! v))))

;; A stream's matches grow at their end, thousands of times, so only the
;; rows they add are given to the list, once it shows as many as it can:
;; the popup's size is that of the rows shown.
(define (%show! l)
  (let* ([s (%shown-session l)] [b (%shown-buffer l)]
         [matches (completion:session-matches s)] [n (completion:matches-count matches)] [m (completion:selected s)])
    (cond
      [(or (not (eq? matches (%shown-matches l))) (and (fx< (%shown-count l) (rows)) (fx> n (%shown-count l))))
       (let ([shown (%first-matches s)])
         (%shown-matches-set! l matches)
         (%shown-count-set! l n)
         (%shown-widths-set! l (%widths s shown))
         (ui:set-rows! b (%list-node b) (%indices 0 n)
                       (lambda (k) (%draw-row l matches k))
                       (lambda (k) (%choose l (completion:matches-ref matches k)))
                       (rows))
         (if (fx= n 0)
             (%close-popup! l)
             (as-module (this-module)
               (%shown-popup-id-set! l
                 (views:id
                   (layout-float:show-at! (completion:session-view s) (completion:session-start s) b
                                          (list 'columns (%popup-width s shown))
                                          (list 'lines (fxmax 1 (length shown)))))))))]
      [(fx> n (%shown-count l))
       (ui:add-rows! b (%list-node b) (%indices (%shown-count l) n))
       (%shown-count-set! l n)])
    ;; Each view of a list selects its own row, so the selection goes to
    ;; the view the popup shows.
    (let ([v (%popup-view l)] [k (and m (%index-of m matches))])
      (when v
        (if k
            (ui:select-row! (%list-node b) v k)
            (views:set-point! v (%empty-position b)))))))

;; A prompt sits in a locked part and a field may be drawn inside another
;; buffer; only a view the user edits in, an unlocked part of the layout,
;; has a place for a popup at point.
(define (%started s)
  (let* ([view (completion:session-view s)] [node (layout:view-node view)])
    (when (and node (not (layout:locked? node)))
      (let* ([b (buffers:make (%next-name) (%root '() (%none '()) (ui:list '())))]
             [l (make-%shown s b #f #f 0 '())])
        (buffers:with-buffer b (set-option-local! views:cursor-visible #f))
        (set! %popups (cons l %popups))))))

(define (%updated s)
  (let ([l (%popup-of s)])
    (when l (%show! l))))

(define (%ended s)
  (let ([l (%popup-of s)])
    (when l
      (set! %popups (remq l %popups))
      (%close-popup! l)
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
