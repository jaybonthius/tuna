#!tuna
(import (ui) (buffers) (document))

(define made (buffers:make "*made*" (ui:list '())))

(define names (vector "p" "q"))

(define (shout i) (ui:label (string-append (vector-ref names i) "!")))

(ui:set-rows! made (document:token (buffers:document made) 0) 2 shout shout)
