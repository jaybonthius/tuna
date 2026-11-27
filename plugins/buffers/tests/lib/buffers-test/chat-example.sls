#!tuna
(import (buffers) (document) (views) (haml) (saved))

(define (draw-transcript node view) (haml (:div.chat (views:draw-children view node))))
(define (draw-reply node view) (haml (:div.reply (views:draw-children view node))))
(define (draw-prompt node view) (haml (:div.prompt (views:draw-children view node))))
(define (refuse-edit node edit) #f)

(buffers:define-kind transcript (content nodes) (draw draw-transcript))
(buffers:define-kind reply (consent refuse-edit) (draw draw-reply))
(buffers:define-kind prompt (draw draw-prompt))

(saved:define-saved replies '() list?)

(define chat
  (or (buffers:find "*chat*")
      (buffers:make "*chat*"
        (apply transcript '() (append (map (lambda (text) (reply '() text)) (replies))
                                      (list (prompt '())))))))

(define (add-reply! text)
  (let ([at (document:node-start (last-prompt))])
    (buffers:with-silent-edits chat
      (buffers:splice! chat at at (document:from-datum (reply '() text))))
    (saved:set! replies (append (replies) (list text)))))

(define (last-prompt)
  (let ([doc (buffers:document chat)])
    (document:enclosing doc (- (document:length doc) 2))))
