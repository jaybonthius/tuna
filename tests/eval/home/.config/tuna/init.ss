(import (hooks) (options) (tables) (timers) (saved))
(import (tuna) (testing) (document) (haml) (web))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin editing)
(use-plugin echo-area)
(use-plugin undo)
(use-plugin modes)
(use-plugin minibuffer)
(use-plugin completion)
(use-plugin files)
(use-plugin actions)
(use-plugin chez-scheme)
(use-plugin chez-scheme-completion)
(use-plugin eval)

(define client (web:add-client! 1))

(define (press! . keys)
  (for-each
    (lambda (key)
      (parameterize ([web:current-client client])
        (views:call-with-view (layout:selected-view) (lambda () (keys:press! client key)))))
    keys))

(define (type! text)
  (for-each (lambda (c) (press! (if (char=? c #\space) "SPC" (string c)))) (string->list text)))

(define (in-client thunk)
  (parameterize ([web:current-client client])
    (views:call-with-view (layout:selected-view) thunk)))


;; A command's prompt pauses its task, so tests press its keys in a task
;; of their own and wait for the prompt.
(define (start! . keys)
  (let ([t (spawn-task (lambda (restore) (apply press! keys)))])
    (testing:wait-until (lambda () (or (eq? (task-state t) 'done) (minibuffer:current-prompt))))
    t))

;; An action's command reads its key in a task of its own, so a test
;; presses the key only once the read waits for it.
(define (act! . keys)
  (let ([t (spawn-task (lambda (restore) (apply press! keys)))])
    (testing:wait-until (lambda () (or (eq? (task-state t) 'done) (keys:reading client))))
    t))

(define (finish t)
  (testing:wait-until (lambda () (eq? (task-state t) 'done)))
  (eq? (task-state t) 'done))

(define (eval! text . prefix)
  (let ([t (apply start! (append prefix (list "M-:")))])
    (type! text)
    (press! "RET")
    (finish t)))

(define (view) (layout:selected-view))

(define (mouse-in! v action place)
  (parameterize ([web:current-client client])
    ((tables:ref web:input-handlers "mouse") client
     (append place
             `(("type" . "mouse") ("action" . ,action) ("button" . 1) ("clicks" . 1) ("modifiers" . #())
               ("view" . ,(views:id v)) ("version" . ,(buffers:version (views:buffer v)))
               ("showing" . ,(views:shown-count v)) ("report" . 1))))))

(define (click-at! v at)
  (mouse-in! v "down" `(("at" . ,at) ("count" . 0)))
  (mouse-in! v "click" `(("at" . ,at) ("count" . 0))))

(define (echo-view) (car (views:showing (buffers:find " *Echo Area*"))))

(define (prompt) (minibuffer:current-prompt))

(define (input) (minibuffer:input (prompt)))

(define (text-of b) (document:text (buffers:document b)))

(define (messages) (text-of (buffers:find "*Messages*")))

(define (message) (echo-area:current-message))

(define (show! b) (views:set-buffer! (view) b) b)

(define (position-of b string offset)
  (let* ([t (text-of b)] [n (string-length string)])
    (let loop ([i 0])
      (if (string=? (substring t i (+ i n)) string)
          (document:position (buffers:document b) (+ i offset) (document:unit characters))
          (loop (+ i 1))))))

(define (at! b string offset) (views:set-point! (view) (position-of b string offset)))

(define (point-text)
  (let* ([b (views:buffer (view))] [doc (buffers:document b)] [p (views:point (view))])
    (string-append (document:text doc 0 p) "-!-" (document:text doc p (document:length doc)))))

(define (log-tail n)
  (let loop ([lines (reverse (cdr (reverse (split-lines (messages)))))] )
    (if (> (length lines) n) (loop (cdr lines)) lines)))

(define (split-lines s)
  (let loop ([i 0] [from 0] [acc '()])
    (cond
      [(= i (string-length s)) (reverse (cons (substring s from i) acc))]
      [(char=? (string-ref s i) #\newline) (loop (+ i 1) (+ i 1) (cons (substring s from i) acc))]
      [else (loop (+ i 1) from acc)])))

(define (without-tags s)
  (let loop ([i 0] [tag? #f] [out '()])
    (cond
      [(= i (string-length s)) (list->string (reverse out))]
      [(char=? (string-ref s i) #\<) (loop (+ i 1) #t out)]
      [(char=? (string-ref s i) #\>) (loop (+ i 1) #f out)]
      [tag? (loop (+ i 1) #t out)]
      [else (loop (+ i 1) #f (cons (string-ref s i) out))])))

(define (prompt-message)
  (let* ([s (html->string (views:draw (minibuffer:prompt-view (prompt)) client))]
         [open "<span class=\"minibuffer-message\""])
    (let loop ([i 0])
      (cond
        [(> (+ i (string-length open)) (string-length s)) #f]
        [(string=? (substring s i (+ i (string-length open))) open)
         (let close ([j i])
           (if (string=? (substring s j (+ j 7)) "</span>")
               (without-tags (substring s i (+ j 7)))
               (close (+ j 1))))]
        [else (loop (+ i 1))]))))

(define (prompt-text) (text-of (views:buffer (minibuffer:prompt-view (prompt)))))

(define (input-point) (- (views:point (minibuffer:prompt-view (prompt))) (minibuffer:input-start (prompt))))

(define (session) (in-client completion:current-session))

(define (session-texts)
  (let* ([s (session)] [ms (completion:session-matches s)])
    (do ([k (- (completion:matches-count ms) 1) (- k 1)] [acc '() (cons (completion:text s (completion:matches-ref ms k)) acc)])
        ((< k 0) acc))))

(define home (getenv "HOME"))

(define (at path) (string-append home "/" path))

(define (write-file! path content)
  (timers:sleep 0.01)
  (with-output-to-file (at path) (lambda () (display content)) 'replace))
(import)
(import (console))
