(import (tuna) (tuna plugins) (document) (haml) (web) (help) (boxes))
(use-plugin split)
(use-plugin layout
  (config
    (set-option! layout:display-action split:display-right)
    (table-set! layout:display-rules help:buffer? split:display-below)))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))

(define (tree)
  (car (document:datums (buffers:document layout:buffer))))

(define (ids) (map views:id (layout:views)))

(define (selected) (views:id (layout:selected-view)))

(define (show-screen client) (display (html->string (layout:screen client))) (newline))
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
