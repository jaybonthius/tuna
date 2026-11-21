(import (tuna) (tuna plugins) (document) (web))
(use-plugin ask
  (config
    (set-option! ask:message-writer (lambda (text) (void)))))
(use-plugin layout)
(use-plugin modes)
(use-plugin undo)
(use-plugin editing)
(use-plugin chez-scheme)

(define-table plain-keymap)
(define-hook plain-hook)
(modes:define-major-mode plain (keymap plain-keymap) (hook plain-hook))

(commands:define-command (break-line)
  "Calls editing:newline from a command's code."
  (editing:newline 1))

(define client (web:add-client! 1))

(define (view) (layout:selected-view))

(define (press! . keys)
  (for-each
    (lambda (key)
      (parameterize ([web:current-client client])
        (views:call-with-view (view)
          (lambda () (keys:press! client key)))))
    keys))

(define (run command . args)
  (parameterize ([web:current-client client])
    (views:call-with-view (view)
      (lambda () (apply commands:run command args)))))

(define cursor-marker #\x2038)
(define mark-marker #\xA6)

(define buffer-count 0)

(define (text b) (document:text (buffers:document b)))

(define start!
  (case-lambda
    [(marked) (start! marked chez-scheme:mode)]
    [(marked mode)
     (set! buffer-count (+ buffer-count 1))
     (let loop ([cs (string->list marked)] [i 1] [acc '()] [points '()] [mark #f])
       (cond
         [(null? cs)
          (let ([b (buffers:make (format "t~a.ss" buffer-count) (list->string (reverse acc)))] [points (reverse points)])
            (modes:set-major-mode mode b)
            (views:set-buffer! (view) b)
            (views:set-point! (view) (car points))
            (when mark (views:set-mark! (view) mark))
            (for-each (lambda (p) (views:add-cursor! (view) p)) (cdr points))
            b)]
         [(char=? (car cs) cursor-marker) (loop (cdr cs) i acc (cons i points) mark)]
         [(char=? (car cs) mark-marker) (loop (cdr cs) i acc points i)]
         [else (loop (cdr cs) (+ i 1) (cons (car cs) acc) points mark)]))]))

(define (shown)
  (let* ([b (views:buffer (view))] [doc (buffers:document b)]
         [points (map views:cursor-point (views:cursors (view)))])
    (let loop ([p 0] [acc '()])
      (if (= p (document:length doc))
          (apply string-append (reverse acc))
          (loop (+ p 1)
                (cons (string-append (if (memv p points) (string cursor-marker) "")
                                     (let ([t (document:token doc p)]) (if (char? t) (string t) "")))
                      acc))))))

(define (after marked . keys)
  (start! marked)
  (apply press! keys)
  (shown))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))
(import (console))
