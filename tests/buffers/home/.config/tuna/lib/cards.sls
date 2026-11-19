#!tuna
(import (buffers) (document))

(define (row-text node) (string-append (document:node-attribute node 'label) "\n"))
(define (tag-text node) (document:node-attribute node 'label))
(define (broken-text node) (car '()))
(define (number-text node) 42)

(buffers:define-kind rows (content nodes))
(buffers:define-kind row (content atom) (text row-text))
(buffers:define-kind tag (content atom) (inline) (text tag-text))
(buffers:define-kind broken (content atom) (text broken-text))
(buffers:define-kind number (content atom) (text number-text))
(buffers:define-kind blank (content atom))
(buffers:define-kind field (inline))

(define (characters-only node edit)
  (let ([inserted (buffers:piece-document (buffers:edit-inserted edit))])
    (let loop ([p 0])
      (or (fx= p (document:length inserted))
          (and (char? (document:token inserted p)) (loop (fx+ p 1)))))))

(buffers:define-kind plain (consent characters-only))
