#!tuna
(import (buffers) (document))

(define (plain-line? node edit)
  (let* ([inserted (buffers:edit-inserted edit)] [text (document:text inserted)])
    (and (= (string-length text) (document:length inserted))
         (for-all (lambda (c) (not (memv c '(#\newline #\xFFFC)))) (string->list text)))))

(define (unchanged? node edit)
  (and (zero? (document:length (buffers:edit-removed edit)))
       (zero? (document:length (buffers:edit-inserted edit)))))

(define (never node edit) #f)

(buffers:define-kind form (content nodes))
(buffers:define-kind row (stops children) (consent unchanged?))
(buffers:define-kind label (inline) (stops none) (consent never))
(buffers:define-kind field (inline) (consent plain-line?))
(buffers:define-kind button (content atom))
