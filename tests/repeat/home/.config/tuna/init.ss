(import (tuna) (tuna plugins) (document) (web) (keys) (buffers) (views) (commands))
(use-plugin layout-split)
(use-plugin layout)

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))

;; Web gives each item's client to the commands its keys run.
(define (press! client . keys)
  (for-each
    (lambda (key)
      (parameterize ([web:current-client client])
        (layout:call-with-frame (layout:frame client)
          (lambda () (keys:press! client key)))))
    keys))

(define (weights)
  (let ([split (cadr (cdr (car (document:datums (buffers:document layout:buffer)))))])
    (map (lambda (part)
           (let ([w (assq 'weight (vector-ref part 1))]) (if w (cdr w) 1)))
         (cddr split))))

(define (keymap-names client)
  (map (lambda (k)
         (cond
           [(eq? k layout-split:resize-keymap) 'layout-split:resize-keymap]
           [(eq? k keys:global) 'keys:global]
           [else 'keymap]))
       (keys:active-keymaps client)))
(import (console))
