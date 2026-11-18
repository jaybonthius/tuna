#!tuna
(import (buffers) (document) (views) (haml) (undo) (markdown))

(define (draw-reply node view) (haml (:div.reply (views:draw-children view node))))
(buffers:define-kind reply (content nodes) (draw draw-reply))
(buffers:define-layer written (read-only))

(define (%make-chat)
  (let ([b (buffers:make "*chat*" (reply '()))])
    (buffers:add-span! (buffers:layer b written) 0 2 '())
    b))

(define chat (or (buffers:find "*chat*") (%make-chat)))

(define %text "")
(define %done? #t)
(define %stale? #f)

(define (receive! piece)
  (set! %text (string-append %text piece))
  (set! %done? #f)
  (set! %stale? #t))

(define (finish!)
  (set! %done? #t)
  (set! %stale? #t))

(define (%show-reply!)
  (when %stale?
    (set! %stale? #f)
    (buffers:reconcile! chat (document:token (buffers:document chat) 0)
      (if %done? (markdown:blocks %text) (markdown:unfinished-blocks %text)))
    (buffers:set-modified! chat #f)))

(buffers:with-buffer chat (set-option-local! undo:limit 0))

(advice-add! batch-ended
  (lambda (ended)
    (guard (c [#t (report c)])
      (as-module (this-module) (%show-reply!)))
    (ended)))
