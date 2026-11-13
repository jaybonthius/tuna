(import (tuna) (tuna plugins) (document) (haml) (web) (help) (boxes))
(use-plugin layout-split)
(use-plugin layout
  (config
    (set-option! layout:display-action layout-split:display-right)
    (table-set! layout:display-rules help:buffer? layout-split:display-below)))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))

(define (tree)
  (car (document:datums (buffers:document layout:buffer))))

(define (ids) (map views:id (layout:views)))

(define (selected) (views:id (layout:selected-view)))

;; Views number their placements from a random base.
(define (show-screen client)
  (let loop ([s (html->string (layout:screen client))] [from 0])
    (let ([i (let find ([i from])
               (cond
                 [(> (+ i 16) (string-length s)) #f]
                 [(string=? (substring s i (+ i 16)) "data-placement=\"") i]
                 [else (find (+ i 1))]))])
      (if i
          (let end ([j (+ i 16)])
            (if (char=? (string-ref s j) #\")
                (loop (string-append (substring s 0 (+ i 16)) "*" (substring s j (string-length s))) (+ i 17))
                (end (+ j 1))))
          (begin (display s) (newline))))))
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
    keys))
(import (console))
