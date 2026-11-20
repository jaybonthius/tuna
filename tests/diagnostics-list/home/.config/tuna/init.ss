(import (tuna) (tuna plugins) (document) (haml) (web))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin editing)
(use-plugin files)
(use-plugin projects)
(use-plugin jump-history)
(use-plugin status-line)
(use-plugin diagnostics
  (config
    (set-option! diagnostics:check-delay #f)))
(use-plugin diagnostics-list
  (config
    (keys:bind! keys:global "C-c l b" diagnostics-list:show-buffer-diagnostics)
    (keys:bind! keys:global "C-c l e" diagnostics-list:show-project-diagnostics)))

(define client (web:add-client! 1))

(define (press! . keys)
  (for-each
    (lambda (key)
      (parameterize ([web:current-client client])
        (views:call-with-view (layout:selected-view) (lambda () (keys:press! client key)))))
    keys))

(define (view) (layout:selected-view))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))

(define (text b) (document:text (buffers:document b)))

(define (search s sub from)
  (let loop ([i from])
    (cond
      [(> (+ i (string-length sub)) (string-length s)) #f]
      [(string=? (substring s i (+ i (string-length sub))) sub) i]
      [else (loop (+ i 1))])))

(define (strip-tags s)
  (let loop ([cs (string->list s)] [in? #f] [acc '()])
    (cond
      [(null? cs) (list->string (reverse acc))]
      [(char=? (car cs) #\<) (loop (cdr cs) #t acc)]
      [(char=? (car cs) #\>) (loop (cdr cs) #f (cons #\space acc))]
      [in? (loop (cdr cs) #t acc)]
      [else (loop (cdr cs) #f (cons (car cs) acc))])))

(define (words s)
  (let loop ([cs (string->list s)] [word '()] [acc '()])
    (define (flush) (if (null? word) acc (cons (list->string (reverse word)) acc)))
    (cond
      [(null? cs) (reverse (flush))]
      [(char-whitespace? (car cs)) (loop (cdr cs) '() (flush))]
      [else (loop (cdr cs) (cons (car cs) word) acc)])))

;; Each row's text, by the list's rows as a view of it draws them.
(define (rows v)
  (let ([html (html->string (views:draw v #f))])
    (let loop ([from 0] [acc '()])
      (let ([i (search html "<div class=\"ui-row\"" from)])
        (if i
            (let ([e (search html "</li>" i)])
              (loop e (cons (words (strip-tags (substring html i e))) acc)))
            (reverse acc))))))

(define (selected v)
  (ui:selected-row (document:token (buffers:document (views:buffer v)) 0) v))

(define (status v)
  (let ([html (html->string (status-line:draw v client))])
    (let ([i (search html "data-segment=\"diagnostics-list:counts\"" 0)])
      (and i (let ([e (search html "</button>" i)]) (words (strip-tags (substring html (search html ">" i) e))))))))

(define (mark-number keymap) (read (open-input-string (views:keymap-mark keymap))))

;; A click on the counts segment of a window's status line: the page
;; sends the number of the keymap the segment is marked with.
(define (counts-mark window)
  (let* ([html (html->string (status-line:draw window client))]
         [i (search html "data-segment=\"diagnostics-list:counts\"" 0)]
         [k (+ (search html "data-keymap=\"" i) 13)])
    (read (open-input-string (substring html k (search html "\"" k))))))

(define (click-counts! window)
  (let ([s layout:screen-view] [at (document:node-start (layout:view-node window))] [mark (counts-mark window)])
    (for-each
      (lambda (action)
        (parameterize ([web:current-client client])
          ((table-ref web:input-handlers "mouse") client
           `(("type" . "mouse") ("action" . ,action) ("button" . 1) ("clicks" . 1) ("modifiers" . #())
             ("view" . ,(views:id s)) ("version" . ,(buffers:version layout:buffer))
             ("showing" . ,(views:shown-count s)) ("token" . ,at)
             ("keymaps" . ,(vector mark (read (open-input-string (views:keymap-mark status-line:keymap)))))))))
      '("down" "click"))))

(define (word b s)
  (let ([t (text b)])
    (let loop ([i 0])
      (if (string=? (substring t i (+ i (string-length s))) s) (+ i 1) (loop (+ i 1))))))

(define (mark b s severity message)
  (diagnostics:make-diagnostic (word b s) (+ (word b s) (string-length s)) severity message))

(define (mode! b on?) (buffers:with-buffer b (set-option-local! diagnostics:mode on?)))

(define root
  (let ([f (format "~a/project" (getenv "HOME"))])
    (unless (file-exists? f) (mkdir f) (mkdir (string-append f "/.git")))
    f))

(define (write-file! name content)
  (let ([path (string-append root "/" name)])
    (with-output-to-file path (lambda () (display content)) 'replace)
    path))

(define notes (files:visit (write-file! "notes.txt" "alpha beta gamma\ndelta epsilon\nzeta eta\n")))
(layout:switch-to-buffer notes)
(set-idle! #t)
(import (console))
