#!tuna
(import (commands) (keys) (layout-split) (web) (tables))

(tables:define-table keymap "Keys while resizing; RET or ESC leaves.")

(define %ends (make-weak-eq-hashtable))

(commands:define-command (enter)
  "Resizes with { and } until RET or ESC."
  (let ([client (web:current-client)])
    ((eq-hashtable-ref %ends client void))
    (eq-hashtable-set! %ends client
      (keys:push-keymap! client keymap (lambda (found command) #t)))))

(commands:define-command (leave)
  "Leaves resize mode."
  ((eq-hashtable-ref %ends (web:current-client) void)))

(keys:bind! keymap "}" layout-split:enlarge)
(keys:bind! keymap "{" layout-split:shrink)
(keys:bind! keymap "RET" leave)
(keys:bind! keymap "ESC" leave)
(keys:bind! keys:global "C-c r" enter)
