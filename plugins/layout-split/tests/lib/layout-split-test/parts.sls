#!tuna
(import (layout) (buffers) (document) (views))

(define (tree) (car (document:datums (buffers:document layout:buffer))))

(define (set-parts! part)
  (let ([n (document:length (buffers:document layout:buffer))])
    (buffers:replace! layout:buffer 1 (- n 1) (document:from-datum part))
    (void)))

(define (atom view . attributes)
  (views:view (cons* (cons 'view (views:id view)) (cons 'buffer (buffers:name (views:buffer view))) attributes)))

(define (named name)
  (or (buffers:find name) (buffers:make name (string-append name "\n"))))

(define (name-of view) (buffers:name (views:buffer view)))

;; An atom keeps the buffer name it was made with, so the outline names
;; the buffer its view shows now, and a split its direction.
(define (outline-of d)
  (cond
    [(vector? d)
     (let ([v (views:find (cdr (assq 'view (vector-ref d 1))))])
       (if v (name-of v) (cdr (assq 'buffer (vector-ref d 1)))))]
    [(eq? (car d) 'layout-split:container)
     (cons (let ([dir (assq 'direction (cadr d))]) (if dir (cdr dir) 'split)) (map outline-of (cddr d)))]
    [else (cons (car d) (map outline-of (cddr d)))]))

(define (outline) (outline-of (tree)))

(define (attributes-of view)
  (let find-in ([d (tree)])
    (if (vector? d)
        (and (eqv? (views:id view) (cdr (assq 'view (vector-ref d 1)))) (cddr (vector-ref d 1)))
        (exists find-in (cddr d)))))

