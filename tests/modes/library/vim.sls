#!tuna
(import (keys) (views) (modes) (commands) (hooks) (tables))

(tables:define-table normal-keymap "Keys in normal state, where typing inserts nothing.")
(tables:define-table insert-keymap "Keys in insert state.")
(tables:define-table normal-keymaps "A mode's own keys in normal state: a major or minor mode, to a keymap.")
(tables:define-table initial-states "The state a view starts in, normal-keymap or insert-keymap, by major mode, looked up along its ancestry.")

(define %states (make-weak-eq-hashtable))

(define (%initial-state view)
  (let ([buffer (views:buffer view)])
    (or (and buffer
             (exists (lambda (m) (tables:ref initial-states m))
                     (modes:ancestry (modes:major-mode buffer))))
        normal-keymap)))

(define (%state view)
  (or (eq-hashtable-ref %states view #f) (%initial-state view)))

(define (state-keymaps client posn)
  (let ([view (if posn (views:posn-view posn) (views:current))])
    (cond
      [(not view) '()]
      [(eq? (%state view) normal-keymap)
       (let ([buffer (views:buffer view)])
         (append
           (filter values
             (map (lambda (m) (tables:ref normal-keymaps m))
                  (append (modes:active-minor-modes view)
                          (if buffer (modes:ancestry (modes:major-mode buffer)) '()))))
           (list normal-keymap)))]
      [else (list insert-keymap)])))

(define (%forget-states buffer)
  (for-each (lambda (view) (eq-hashtable-delete! %states view)) (views:showing buffer)))

(commands:define-command (insert-state)
  "Makes keys type until ESC."
  (eq-hashtable-set! %states (views:current) insert-keymap))

(commands:define-command (normal-state)
  "Makes keys run commands."
  (eq-hashtable-set! %states (views:current) normal-keymap))

(keys:bind! normal-keymap "<printing-char>" keys:undefined)
(keys:bind! normal-keymap "i" insert-state)
(keys:bind! insert-keymap "ESC" normal-state)
(hooks:add! keys:find-keymaps state-keymaps 25)
(hooks:add! modes:major-mode-changed %forget-states)
