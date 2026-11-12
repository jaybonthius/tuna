(import (tuna) (tuna plugins))
(use-plugin kill-ring
  (config
    (set-option! kill-ring:skip-duplicates #t)))
(import (document) (buffers))

(define pushed '())
(define (note-push entry) (set! pushed (cons (kill-ring:text entry) pushed)))
(add-hook! kill-ring:after-push note-push)
(define (take-pushed!)
  (let ([p (reverse pushed)]) (set! pushed '()) p))

(define (contents b) (document:text (buffers:document b)))
(define (root b) (car (document:datums (buffers:document b))))

(define (spans-of b type)
  (map (lambda (s) (list (document:text (buffers:document b) (car s) (cadr s)) (caddr s)))
       (buffers:spans (buffers:layer b type) 0 (document:length (buffers:document b)))))

(define (raised thunk)
  (guard (c [#t (list (condition-who c) (condition-message c))])
    (thunk)))

(define (wait-until done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 1000))
      (sleep-for 0.01)
      (loop (+ n 1)))))

(define saved-file
  (string-append (getenv "HOME") "/.local/share/tuna/saved/tuna/kill-ring/texts.ss"))

(define (saved-texts)
  (and (file-exists? saved-file)
       (call-with-input-file saved-file read)))

(define (ring-texts)
  (map (lambda (entry) (map (lambda (piece) (kill-ring:text (list piece))) entry))
       (kill-ring:entries)))
(import (console))
