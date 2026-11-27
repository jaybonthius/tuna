#!tuna
(import (ui) (buffers) (document) (commands) (keys))

(define made (buffers:make "*made2*" (ui:list '())))

(define names (vector "p" "q"))

(define (shout i) (ui:label (string-append (vector-ref names i) "!")))

(commands:define-command (fill-made) "Fills the list."
  (ui:set-rows! made (document:token (buffers:document made) 0) 2 shout shout))

(keys:bind! keys:global "C-c m" fill-made)
