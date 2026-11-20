#!tuna
(import (completion) (completion rows) (minibuffer) (buffers) (views) (keys) (editing) (faces) (web) (haml))

(define-option lines 10 (lambda (v) (and (fixnum? v) (fx> v 0)))
  "How many lines a read's list shows at most, its rows and their group titles.")

(define-option fixed-height? #f boolean?
  "When true, a read's list is completion-list:lines tall from its first draw; otherwise it grows as rows arrive and keeps its height until the read ends.")

(define (%draw-count node view) (%counts view))

(define (%draw-root node view)
  (let ([l (%list-of-view view)])
    (haml (:div.completion-list ([style (string-append "--completion-list-lines:"
                                          (number->string (if (or (fixed-height?) (not l)) (lines) (%shown-height l))))])
            (views:draw-children view node)))))

(buffers:define-kind %root (content nodes) (draw %draw-root))

(buffers:define-kind %count-line (content atom) (draw %draw-count))

(define-record-type %shown
  (sealed #t)
  (fields rows view prompt (mutable height)))

(define %lists '())

(define (%list-of s) (find (lambda (l) (eq? (completion/rows:session (%shown-rows l)) s)) %lists))

(define (%list-of-view view) (find (lambda (l) (eq? (%shown-view l) view)) %lists))

(define (%counts view)
  (let ([l (%list-of-view view)])
    (if l
        (let* ([s (completion/rows:session (%shown-rows l))] [matches (completion:session-matches s)]
               [m (completion:selected s)]
               [k (and m (completion:matches-index matches m))])
          (haml (:div.completion-list-count ([data-face (symbol->string faces:shadow)])
                  (if k (fx+ k 1) 0) "/" (completion:matches-count matches)
                  (when (completion:session-busy? s) " …")
                  (let ([narrowed (completion:narrowed s)])
                    (when narrowed (haml (:span.completion-list-narrowed narrowed)))))))
        '())))

(define (%started s)
  (let ([p (completion:session-prompt s)])
    (when p
      (let* ([r (completion/rows:make s lines (lambda (nodes) (apply %root '() (%count-line '()) nodes)))]
             [v (views:make (completion/rows:buffer r))])
        (set! %lists (cons (make-%shown r v p 0) %lists))
        (minibuffer:set-content! p (list (views:view (list (cons 'view (views:id v))
                                                           (cons 'buffer (buffers:name (completion/rows:buffer r)))))))))))

;; The list never shrinks during a read, so the input above it does not
;; jump back and forth as the matches change.
(define (%updated s)
  (let ([l (%list-of s)])
    (when l
      (completion/rows:update! (%shown-rows l))
      (%shown-height-set! l (fxmax (%shown-height l) (completion/rows:lines (%shown-rows l)))))))

(define (%ended s)
  (let ([l (%list-of s)])
    (when l
      (set! %lists (remq l %lists))
      (completion/rows:drop! (%shown-rows l)))))

;; A running session's prompt is waiting, so its content can be cleared.
(define (%unload)
  (for-each
    (lambda (l)
      (minibuffer:set-content! (%shown-prompt l) '())
      (%ended (completion/rows:session (%shown-rows l))))
    %lists))

(keys:remap! completion:keymap editing:next-line completion:next)
(keys:remap! completion:keymap editing:previous-line completion:previous)
(keys:remap! completion:keymap editing:beginning-of-buffer completion:first)
(keys:remap! completion:keymap editing:end-of-buffer completion:last)
(keys:remap! completion:keymap views:scroll-up completion/rows:scroll-up)
(keys:remap! completion:keymap views:scroll-down completion/rows:scroll-down)
(keys:remap! completion:keymap editing:kill-ring-save completion:kill-ring-save)
;; The keys of Emacs's paragraph motions, which Vertico remaps: Tuna has no
;; paragraph motions to remap.
(keys:bind! completion:keymap "M-}" completion:next-group)
(keys:bind! completion:keymap "M-{" completion:previous-group)
(table-set! web:stylesheets 'completion-list "completion-list/completion-list.css")
(add-hook! completion:started %started)
(add-hook! completion:updated %updated)
(add-hook! completion:ended %ended)
(on-unload %unload)
