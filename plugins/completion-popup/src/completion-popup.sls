#!tuna
(import (completion) (completion rows) (buffers) (views) (keys) (commands) (editing) (modes) (layout) (layout-float) (web) (haml) (hooks) (options) (tables) (timers))

(define %self (current-owner))

(options:define-option lines 10 (lambda (v) (and (fixnum? v) (fx> v 0)))
  "How many lines a popup shows at most, its rows and their group titles.")

(options:define-option min-width 15 (lambda (v) (and (fixnum? v) (fx> v 0)))
  "How many columns a popup is wide at least.")

(options:define-option max-width 100 (lambda (v) (and (fixnum? v) (fx> v 0)))
  "How many columns a popup is wide at most.")

(options:define-option auto-delay #f (lambda (v) (or (not v) (and (real? v) (>= v 0))))
  "Seconds after a command of completion-popup:auto-commands before completion at point starts by itself; #f never.")

(options:define-option auto-prefix 3 (lambda (v) (and (fixnum? v) (fx>= v 0)))
  "How many characters the completed text must hold before point for completion to start by itself.")

(options:define-option auto-commands (list editing:self-insert editing:delete-backward-char editing:delete-char editing:delete-forward-char)
  (lambda (v) (and (list? v) (for-all commands:command? v)))
  "The commands after which completion at point starts by itself, once completion-popup:auto-delay has passed.")

(tables:define-table mode-keymap "Keys in a popup's rows' buffer: none, as in completion/rows:mode-keymap.")

(hooks:define-hook mode-hook
  "Called with a popup's rows' buffer current when its mode is set, after completion/rows:mode-hook; it changes the popup and not a read's list.")

(modes:define-major-mode mode (parent completion/rows:mode) (keymap mode-keymap) (hook mode-hook) (plugin-only #t))

;; The popup is as wide as its rows, which only the page measures, so its
;; bounds go to the page too.
(define (%draw-root node view)
  (haml (:div.completion-popup ([style (string-append "--completion-popup-min-width:" (number->string (min-width))
                                                      "ch;--completion-popup-max-width:" (number->string (max-width)) "ch")])
          (views:draw-children view node))))

(buffers:define-kind %root (content nodes) (draw %draw-root))

(define-record-type %shown
  (sealed #t)
  (fields rows (mutable popup-id) (mutable lines)))

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
        (call-as-owner %self
          (lambda ()
            (%shown-popup-id-set! l
              (views:id
                (layout-float:show-at! view (completion:session-start s) (completion/rows:buffer r)
                                       'content (list 'lines (fxmax 1 (%shown-lines l))))))
            (completion/rows:follow-selection! r))))))

(define (%started s)
  (unless (completion:session-prompt s)
    (set! %popups (cons (make-%shown (completion/rows:make s lines (lambda (nodes) (apply %root '() nodes)) mode) #f 0)
                        %popups))))

;; A stream that adds rows while fewer than fit are shown makes the popup
;; taller, so it is placed again when its lines change too.
(define (%updated s)
  (let ([l (%popup-of s)])
    (when l
      (let* ([r (%shown-rows l)] [afresh? (completion/rows:update! r)] [n (completion/rows:lines r)])
        (when (or afresh? (not (fx= n (%shown-lines l))))
          (%shown-lines-set! l n)
          (%place! l))))))

(define (%ended s)
  (let ([l (%popup-of s)])
    (when l
      (set! %popups (remq l %popups))
      (%close-popup! l)
      (completion/rows:drop! (%shown-rows l)))))

(define %timer #f)

;; A minor mode that remaps one of these commands, as strict balance
;; remaps self-insert, runs its own command for the same keys.
(define (%auto-command? client command)
  (exists (lambda (auto) (or (eq? auto command) (eq? (keys:command-remapping client auto) command))) (auto-commands)))

(define (%maybe-start command)
  (when %timer
    (timers:cancel! %timer)
    (set! %timer #f))
  (let ([view (views:current)] [client (web:current-client)])
    (when (and view client (%auto-command? client command) (not (completion:current-session)))
      (let ([delay (auto-delay)] [minimum (auto-prefix)] [id (views:id view)])
        (when delay
          (call-as-owner %self
            (lambda ()
              (set! %timer
                (timers:run-after delay
                  (lambda ()
                    (set! %timer #f)
                    (when (and (views:find id) (views:buffer view))
                      (parameterize ([web:current-client client])
                        (views:call-with-view view (lambda () (completion:start-at-point minimum)))))))))))))))

(define (%unload)
  (when %timer (timers:cancel! %timer))
  (for-each (lambda (l) (%ended (completion/rows:session (%shown-rows l)))) %popups))

(keys:remap! completion:region-keymap editing:next-line completion:next)
(keys:remap! completion:region-keymap editing:previous-line completion:previous)
(keys:remap! completion:region-keymap editing:beginning-of-buffer completion:first)
(keys:remap! completion:region-keymap editing:end-of-buffer completion:last)
(keys:remap! completion:region-keymap views:scroll-up completion/rows:scroll-up)
(keys:remap! completion:region-keymap views:scroll-down completion/rows:scroll-down)
(keys:bind! completion:region-keymap "M-n" completion:next)
(keys:bind! completion:region-keymap "M-p" completion:previous)
(tables:set! web:stylesheets 'completion-popup "completion-popup/completion-popup.css")
(hooks:add! completion:started %started)
(hooks:add! completion:updated %updated)
(hooks:add! completion:ended %ended)
(hooks:add! commands:after-command %maybe-start)
(on-unload %unload)
