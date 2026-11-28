#!tuna
(import (test-runner) (layout) (layout-split) (buffers) (document) (views) (test-user))

(define (tree) (car (document:datums (buffers:document layout:buffer))))

(define (set-parts! part)
  (let ([n (document:length (buffers:document layout:buffer))])
    (buffers:replace! layout:buffer 1 (- n 1) (document:from-datum part))
    (void)))

(define (atom view . attributes)
  (views:view (cons* (cons 'view (views:id view)) (cons 'buffer (buffers:name (views:buffer view))) attributes)))

(define (named name)
  (or (buffers:find name) (buffers:make name (string-append name "\n"))))

(define (view-named name) (views:make (named name)))

(define (name-of view) (buffers:name (views:buffer view)))

;; An atom keeps the buffer name it was made with, so the outline names
;; the buffer its view shows now.
(define (atom-name d)
  (let* ([attributes (vector-ref d 1)] [v (views:find (cdr (assq 'view attributes)))])
    (if v (name-of v) (cdr (assq 'buffer attributes)))))

(define (outline-of d)
  (if (vector? d) (atom-name d) (cons (car d) (map outline-of (cddr d)))))

(define (outline) (outline-of (tree)))

(define (attributes-of view)
  (let find-in ([d (tree)])
    (if (vector? d)
        (and (eqv? (views:id view) (cdr (assq 'view (vector-ref d 1)))) (vector-ref d 1))
        (exists find-in (cddr d)))))

(define (names) (map name-of (layout:views)))

(define (selected-name) (name-of (layout:selected-view)))

(define (order-names) (map name-of (layout:selection-order)))

;; The layout's screen names a part only through an element marked with
;; the part's tokens, such as a view's or a tab's, so a click names it
;; through that element.
(define marked-element
  (case-lambda
    [(class at) (marked-element (test-user:client) class at)]
    [(client class at)
     (or (find (lambda (e) (equal? (number->string at) (test-user:element-attribute e "data-at")))
               (test-user:elements (test-user:screen client) class))
         (assertion-violation 'layout-test/parts:marked-element "no element of the class marked at the position" class at))]))

(define (view-element v) (marked-element "layout-view" (document:node-start (layout:view-node v))))

(define (place-echo! b)
  (layout:display-buffer b (layout-split:display-at-side (layout:direction down) 90 'content '((locked . #t)))))

(define (class-names element)
  (let ([value (test-user:element-attribute element "class")])
    (if value
        (let loop ([chars (string->list value)] [word '()] [words '()])
          (let ([add (lambda () (if (null? word) words (cons (list->string (reverse word)) words)))])
            (cond
              [(null? chars) (reverse (add))]
              [(char=? (car chars) #\space) (loop (cdr chars) '() (add))]
              [else (loop (cdr chars) (cons (car chars) word) words)])))
        '())))

(define (has-class? element class) (and (member class (class-names element)) #t))

(define (drawn-views client)
  (map (lambda (e)
         (cons (string->number (test-user:element-attribute (car (test-user:elements e "view")) "data-view"))
               (has-class? e "selected")))
       (test-user:elements (test-user:screen client) "layout-view")))

(define (part)
  (let* ([n (layout:selected-part)] [doc (buffers:document layout:buffer)])
    (outline-of (car (document:datums (document:slice doc (document:node-start n) (document:node-end n)))))))

