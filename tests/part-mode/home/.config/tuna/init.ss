(import (tuna) (tuna plugins) (document) (haml) (web) (layout-split))
(use-plugin layout-split)
(use-plugin layout-tabs)
(use-plugin layout-scroll)
(use-plugin layout-float)
(use-plugin undo)
(use-plugin editing)
(use-plugin layout)

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))

(define (tree)
  (car (document:datums (buffers:document layout:buffer))))

(define (selected) (views:id (layout:selected-view)))

(define (shape d)
  (if (vector? d) (cdr (assq 'view (vector-ref d 1))) (map shape (cddr d))))

(define (part)
  (let ([n (layout:selected-part)])
    (shape (car (document:datums (document:slice (buffers:document layout:buffer) (document:node-start n) (document:node-end n)))))))

;; The user's windows: the part of the level beside the echo area when
;; there is one, else the root's part.
(define (main)
  (let ([p (caddr (tree))])
    (if (and (pair? p) (eq? (car p) 'layout-split:container) (pair? (caddr p)) (eq? (car (caddr p)) 'layout:level))
        (caddr (caddr p))
        p)))

(define (atom view . attributes)
  (views:view (cons* (cons 'view (views:id view)) (cons 'buffer (buffers:name (views:buffer view))) attributes)))

(define (set-parts! . parts)
  (let ([n (document:length (buffers:document layout:buffer))])
    (buffers:replace! layout:buffer 1 (- n 1) (apply document:from-datum parts))
    (void)))

(define (press! client . keys)
  (for-each
    (lambda (key)
      ((table-ref web:input-handlers "key") client
       (list (cons "type" "key") (cons "key" (car key)) (cons "code" "") (cons "modifiers" (list->vector (cdr key))))))
    keys)
  (batch-ended))

(define (type! client . keys)
  (apply press! client (map list keys)))

(define (screen-of client) (html->string (layout:screen client)))

(define (search text needle)
  (let ([n (string-length needle)])
    (let loop ([i 0])
      (cond
        [(> (+ i n) (string-length text)) #f]
        [(string=? (substring text i (+ i n)) needle) i]
        [else (loop (+ i 1))]))))
(define (placement client)
  (let* ([html (screen-of client)] [i (+ (search html "data-placement=\"") 16)])
    (let loop ([j i]) (if (char-numeric? (string-ref html j)) (loop (+ j 1)) (string->number (substring html i j))))))
(import (console))
