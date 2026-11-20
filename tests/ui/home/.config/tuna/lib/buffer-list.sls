#!tuna
(import (ui) (buffers) (document) (layout) (commands))

(define list-buffer
  (or (buffers:find "*buffer list*") (buffers:make "*buffer list*" (ui:list '()))))

(commands:define-command (list-buffers)
  "Shows the live buffers; RET or a click on one shows it."
  (let ([bs (list->vector (buffers:all))])
    (ui:set-rows! list-buffer (document:token (buffers:document list-buffer) 0) (vector-length bs)
                  (lambda (i) (ui:label (buffers:name (vector-ref bs i))))
                  (lambda (i) (layout:switch-to-buffer (vector-ref bs i)))))
  (layout:switch-to-buffer list-buffer))
