(import (tuna) (tuna plugins) (document) (haml) (web))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin editing)
(use-plugin echo-area)
(use-plugin markdown)
(use-plugin minibuffer)
(use-plugin docs-at-point
  (config
    (set-option! docs-at-point:delay 0.05)))
(use-plugin docs-at-point-display)

(define client (web:add-client! 1))

(define (press! . keys)
  (for-each
    (lambda (key)
      (parameterize ([web:current-client client])
        (views:call-with-view (layout:selected-view) (lambda () (keys:press! client key)))))
    keys))

(define (view) (layout:selected-view))

(define (wait-until done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 300))
      (sleep-for 0.01)
      (loop (+ n 1)))))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))

(define (text b) (document:text (buffers:document b)))

(define (messages) (text (buffers:find "*Messages*")))

;; The signature of the word at point, with the word in a face, as a
;; language's source gives one.
(define asked '())
(define (word-at view)
  (let* ([b (views:buffer view)] [p (views:point view)]
         [s (editing:forward-word-position b (min (+ p 1) (- (document:length (buffers:document b)) 1)) -1)]
         [e (editing:forward-word-position b s 1)])
    (document:text (buffers:document b) s e)))
(define (signature view)
  (set! asked (cons (views:id view) asked))
  (let ([word (word-at view)])
    (docs-at-point:make-doc (string-append "(" word " x)")
      (docs-at-point:doc-options [thing word] [spans (list (list (+ 2 (string-length word)) (+ 3 (string-length word)) faces:highlight))]))))
(add-hook! docs-at-point:sources signature)

(define notes (buffers:make "notes" "alpha beta\ngamma\n"))
(layout:switch-to-buffer notes)
;; A second view, where *Docs* shows when the user asks for it.
(define notes-view (layout:selected-view))
(define other-view (layout-split:split-view! notes-view (layout-split:direction row)))

(define (in-client thunk)
  (parameterize ([web:current-client client])
    (views:call-with-view (layout:selected-view) thunk)))
(define (start! thunk)
  (let ([t (spawn-task (lambda () (in-client thunk)))])
    (sleep-for 0.05)
    t))
(define (type! s)
  (for-each (lambda (c) (press! (if (char=? c #\space) "SPC" (string c)))) (string->list s)))
(define (prompt) (minibuffer:current-prompt))
(define (input) (minibuffer:input (prompt)))
(define (between s open close)
  (define (search sub from)
    (let loop ([i from])
      (cond
        [(> (+ i (string-length sub)) (string-length s)) #f]
        [(string=? (substring s i (+ i (string-length sub))) sub) i]
        [else (loop (+ i 1))])))
  (let ([i (search open 0)])
    (and i (substring s i (+ (search close i) (string-length close))))))
(define (bracket)
  (between (html->string (views:draw (minibuffer:prompt-view (prompt)) client)) "<span class=\"minibuffer-message\"" "</span>"))
(set-idle! #t)
(import (console))
