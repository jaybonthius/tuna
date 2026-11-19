#!tuna
(import (completion) (completion rows) (buffers) (views) (keys) (commands) (editing) (layout) (layout-float) (web))

(define-option rows 10 (lambda (v) (and (fixnum? v) (fx> v 0)))
  "How many rows a popup shows.")

(define-option min-width 15 (lambda (v) (and (fixnum? v) (fx> v 0)))
  "How many columns a popup is wide at least.")

(define-option max-width 100 (lambda (v) (and (fixnum? v) (fx> v 0)))
  "How many columns a popup is wide at most.")

(define-option auto-delay #f (lambda (v) (or (not v) (and (real? v) (>= v 0))))
  "Seconds after a command of completion-popup:auto-commands before completion at point starts by itself; #f never.")

(define-option auto-prefix 3 (lambda (v) (and (fixnum? v) (fx>= v 0)))
  "How many characters the completed text must hold before point for completion to start by itself.")

(define-option auto-commands (list editing:self-insert editing:delete-backward-char editing:delete-char)
  (lambda (v) (and (list? v) (for-all commands:command? v)))
  "The commands after which completion at point starts by itself, once completion-popup:auto-delay has passed.")

(buffers:define-kind %root (content nodes))

(define-record-type %shown
  (sealed #t)
  (fields rows (mutable popup-id)))

(define %popups '())

(define (%popup-of s) (find (lambda (l) (eq? (completion/rows:session (%shown-rows l)) s)) %popups))

;; The popup's view is dropped once layout-float removes it, as when the
;; completed text's view goes, so it is kept by number.
(define (%close-popup! l)
  (let* ([id (%shown-popup-id l)] [v (and id (views:find id))])
    (%shown-popup-id-set! l #f)
    (when (and v (layout:popup-node v))
      (layout-float:close! v))))

;; A view drawn inside another buffer, such as a field's, is not placed by
;; the layout, so a popup has nothing to anchor to there.
(define (%placed? view) (or (layout:view-node view) (layout:popup-node view)))

(define (%place! l)
  (let* ([r (%shown-rows l)] [s (completion/rows:session r)] [view (completion:session-view s)])
    (if (or (fx= (completion:matches-count (completion:session-matches s)) 0) (not (%placed? view)))
        (%close-popup! l)
        (as-module (this-module)
          (%shown-popup-id-set! l
            (views:id
              (layout-float:show-at! view (completion:session-start s) (completion/rows:buffer r)
                                     (list 'columns (fxmax (min-width) (fxmin (max-width) (completion/rows:width r))))
                                     (list 'lines (fxmax 1 (completion/rows:lines r))))))
          (completion/rows:follow-selection! r)))))

(define (%started s)
  (unless (completion:session-prompt s)
    (set! %popups (cons (make-%shown (completion/rows:make s rows (lambda (nodes) (apply %root '() nodes))) #f)
                        %popups))))

(define (%updated s)
  (let ([l (%popup-of s)])
    (when (and l (completion/rows:update! (%shown-rows l)))
      (%place! l))))

(define (%ended s)
  (let ([l (%popup-of s)])
    (when l
      (set! %popups (remq l %popups))
      (%close-popup! l)
      (completion/rows:drop! (%shown-rows l)))))

(define %timer #f)

(define (%maybe-start command)
  (when %timer
    (cancel-timer! %timer)
    (set! %timer #f))
  (let ([view (views:current)] [client (web:current-client)])
    (when (and view client (memq command (auto-commands)) (not (completion:current-session)))
      (let ([delay (auto-delay)] [minimum (auto-prefix)] [id (views:id view)])
        (when delay
          (as-module (this-module)
            (set! %timer
              (run-with-timer delay
                (lambda ()
                  (set! %timer #f)
                  (when (and (views:find id) (views:buffer view))
                    (parameterize ([web:current-client client])
                      (views:call-with-view view (lambda () (completion:start-at-point minimum))))))))))))))

(define (%unload)
  (when %timer (cancel-timer! %timer))
  (for-each (lambda (l) (%ended (completion/rows:session (%shown-rows l)))) %popups))

(keys:remap! completion:region-keymap editing:next-line completion:next)
(keys:remap! completion:region-keymap editing:previous-line completion:previous)
(keys:remap! completion:region-keymap editing:beginning-of-buffer completion:first)
(keys:remap! completion:region-keymap editing:end-of-buffer completion:last)
(keys:bind! completion:region-keymap "M-n" completion:next)
(keys:bind! completion:region-keymap "M-p" completion:previous)
(add-hook! completion:started %started)
(add-hook! completion:updated %updated)
(add-hook! completion:ended %ended)
(add-hook! commands:after-command %maybe-start)
(on-unload %unload)
