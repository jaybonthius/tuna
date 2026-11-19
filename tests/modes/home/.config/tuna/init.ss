(import (tuna) (tuna plugins) (document) (web) (disk))
(use-plugin layout)
(use-plugin modes)
(use-plugin auto-mode)
(use-plugin text
  (config
    (set-option! auto-mode:default-mode text:mode)))
(use-plugin fill)
(use-plugin python
  (config
    (table-set! auto-mode:file-names "SConstruct" python:mode)
    (table-set! modes:lighters python:mode "Py")
    (add-hook! python:mode-hook
      (lambda () (set-option-local! fill:mode #t)))))

(define client (web:add-client! 1))

(define (press! . keys)
  (for-each
    (lambda (key)
      (parameterize ([web:current-client client])
        (views:call-with-view (layout:selected-view)
          (lambda () (keys:press! client key)))))
    keys))

(define (in-frame thunk)
  (parameterize ([web:current-client client])
    (views:call-with-view (layout:selected-view) thunk)))

(define (view) (layout:selected-view))

(define (show! b)
  (views:set-buffer! (view) b)
  b)

(define (text b) (document:text (buffers:document b)))

(define (local option b) (buffers:with-buffer b (option)))

;; Keymaps print as their whole tables, so tests name the ones they know.
(define known-keymaps '())

(define (know! . pairs)
  (let loop ([pairs pairs])
    (unless (null? pairs)
      (set! known-keymaps (cons (cons (car pairs) (cadr pairs)) known-keymaps))
      (loop (cddr pairs)))))

(define (keymap-name k)
  (let ([found (assq k known-keymaps)])
    (if found (cdr found) 'keymap)))

(define (active-keymaps)
  (map keymap-name (in-frame (lambda () (keys:active-keymaps client)))))

(know! keys:global 'keys:global layout:keymap 'layout:keymap
       modes:fundamental-keymap 'modes:fundamental-keymap
       text:keymap 'text:keymap prog:keymap 'prog:keymap python:keymap 'python:keymap
       fill:keymap 'fill:keymap)

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))
(import (console))
