#!tuna
(import (buffers) (document))

;; A box, so a test changes what the kind gives after a kill took it.
(define badge-suffix (box ""))

(define (badge-text node) (string-append (document:node-attribute node 'label) (unbox badge-suffix)))

(buffers:define-kind doc (content nodes))
(buffers:define-kind para)
(buffers:define-kind link (inline) (sticky neither))
(buffers:define-kind image (content atom) (inline))
(buffers:define-kind badge (content atom) (inline) (text badge-text))

(define (one-line? node edit)
  (not (memv #\newline (string->list (document:text (buffers:piece-document (buffers:edit-inserted edit)))))))

(buffers:define-kind field (consent one-line?))
(buffers:define-kind form (content nodes))
