#!tuna
(import (completion) (buffers) (document) (views) (editing) (hooks))

(completion:define-category word-category "Words of the current buffer.")

(define (buffer-words buffer)
  (let ([text (document:text (buffers:document buffer))] [seen (make-hashtable string-hash string=?)])
    (let loop ([i 0] [start #f] [acc '()])
      (define (word-end) (if start (let ([w (substring text start i)]) (if (hashtable-contains? seen w) acc (begin (hashtable-set! seen w #t) (cons w acc)))) acc))
      (cond
        [(= i (string-length text)) (list->vector (reverse (word-end)))]
        [(or (char-alphabetic? (string-ref text i)) (char=? (string-ref text i) #\-) (char=? (string-ref text i) #\:) (char=? (string-ref text i) #\!))
         (loop (+ i 1) (or start i) acc)]
        [else (loop (+ i 1) #f (word-end))]))))

(define (complete-word)
  (let* ([view (views:current)] [buffer (views:buffer view)] [point (views:point view)]
         [start (editing:forward-word-position buffer point -1)])
    (and (< start point)
         (= (editing:forward-word-position buffer start 1) point)
         (completion:region start point
           (list (completion:source
                   (candidates (lambda (prefix) (buffer-words buffer)))
                   (category word-category)))))))

(hooks:add! completion:find-region complete-word 10)
