(import (options) (tables) (timers))
(import (tuna) (testing) (document) (haml) (web))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin layout-tabs)
(use-plugin layout-scroll)
(use-plugin layout-float)
(use-plugin editing)
(use-plugin echo-area)
(use-plugin undo)
(use-plugin minibuffer)
(use-plugin completion)
(use-plugin buffer-picker)
(use-plugin help (config (options:set! help:select-view? #t)))
(use-plugin status-line)
(use-plugin recent-views
  (config
    (options:set! recent-views:delay 0.05)
    (keys:bind! keys:global "s-o" recent-views:select-recent-view)))

;; At exit modules unload newest first, and a container plugin that goes
;; before minibuffer leaves parts of a kind layout no longer knows, which
;; minibuffer's removal of its own part would move; so the checks load
;; after the plugins, as a user's configuration does.
(import (focus-checks))

(define client (web:add-client! 1))

(define (in-client thunk)
  (parameterize ([web:current-client client])
    (views:call-with-view (layout:selected-view) thunk)))

(define (press! . keys)
  (for-each (lambda (key) (in-client (lambda () (keys:press! client key)))) keys))


;; A prompt pauses its command's task, so a test reads in a task of its
;; own and waits for the prompt.
(define (ask!)
  (let ([t (spawn-task (lambda (restore) (guard (c [(cancelled? c) 'quit]) (in-client (lambda () (minibuffer:read "Q: "))))))])
    (testing:wait-until minibuffer:current-prompt)
    t))

(define (start-keys! . keys)
  (let ([t (spawn-task (lambda (restore) (guard (c [(cancelled? c) 'quit]) (apply press! keys))))])
    (testing:wait-until (lambda () (or (minibuffer:current-prompt) (eq? (task-state t) 'done))))
    t))

(define (end! t . keys)
  (cond
    [(pair? keys) (apply press! keys)]
    [(eq? (layout:selected-view) (prompt-view)) (press! "C-g")]
    [else (in-client minibuffer:abort)])
  (testing:wait-until (lambda () (eq? (task-state t) 'done)))
  (void))

(define (prompt!) (end! (ask!)))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))

(define (tree) (car (document:datums (buffers:document layout:buffer))))

(define (set-parts! . parts)
  (let ([n (document:length (buffers:document layout:buffer))])
    (buffers:replace! layout:buffer 1 (- n 1) (apply document:from-datum parts))
    (void)))

(define (atom v . attributes)
  (views:view (cons* (cons 'view (views:id v)) (cons 'buffer (buffers:name (views:buffer v))) attributes)))

;; Each view a test names shows a buffer of that name, or is named once
;; made, so results read as the names the sequences use.
(define names '())

(define (name! v name) (set! names (cons (cons v name) names)) v)

(define (view-named name)
  (let ([b (or (buffers:find name) (buffers:make name (string-append name "\n")))])
    (name! (views:make b) name)))

(define (who v)
  (cond
    [(not v) #f]
    [(assq v names) => cdr]
    [else (buffers:name (views:buffer v))]))

(define (selected) (who (layout:selected-view)))

(define (order) (map who (layout:selection-order)))

(define (front n) (map buffers:name (list-head (buffers:all) n)))

(define (part-of v) (or (layout:view-node v) (layout:popup-node v)))

(define (other-than v) (find (lambda (w) (not (eq? w v))) (layout:views)))

(define echo-buffer (buffers:find " *Echo Area*"))

(define (echo) (layout:find-view echo-buffer))

(name! (echo) "echo")

(define minibuf (buffers:find " *Minibuf*"))

(define (prompt-view) (let ([p (minibuffer:current-prompt)]) (and p (minibuffer:prompt-view p))))

(define (explorer!)
  (name! ((layout-split:display-at-side (layout:direction left) 50 '(columns 20)) (or (buffers:find "explorer") (buffers:make "explorer" "x\n")))
         "explorer"))

(define (palette-prompts!)
  (tables:set! layout:display-rules minibuffer:buffer? layout-float:display-palette))

(define (click-part! node)
  (let ([s layout:screen-view])
    (for-each
      (lambda (action)
        (parameterize ([web:current-client client])
          ((tables:ref web:input-handlers "mouse") client
           `(("token" . ,(document:node-start node)) ("type" . "mouse") ("action" . ,action) ("button" . 1)
             ("clicks" . 1) ("modifiers" . #()) ("view" . ,(views:id s)) ("version" . ,(buffers:version layout:buffer))
             ("showing" . ,(views:shown-count s))))))
      '("down" "click"))))

(define (reset! part)
  (set-parts! part)
  (name! ((layout-split:display-at-side (layout:direction down) 90 'content '((locked . #t))) echo-buffer) "echo")
  (void))

(define (begin! name)
  (let ([v (view-named name)])
    (reset! (atom v))
    (layout:select! v)
    v))

(define (made-beside v name)
  (name! (find (lambda (w) (not (or (eq? w v) (assq w names) (layout:locked? (layout:view-node w))))) (layout:views)) name))

(define (search s sub from)
  (let loop ([i from])
    (cond
      [(> (+ i (string-length sub)) (string-length s)) #f]
      [(string=? (substring s i (+ i (string-length sub))) sub) i]
      [else (loop (+ i 1))])))

(define (float-z)
  (let ([s (html->string (layout:screen client))] [key "--layout-float-z:"])
    (let loop ([i 0] [acc '()])
      (let ([j (search s key i)])
        (if j
            (let* ([k (+ j (string-length key))]
                   [e (let next ([e k]) (if (char-numeric? (string-ref s e)) (next (+ e 1)) e))])
              (loop e (cons (string->number (substring s k e)) acc)))
            (reverse acc))))))

(define (mark-number keymap) (read (open-input-string (views:keymap-mark keymap))))

(define (click-status! window button)
  (let ([s layout:screen-view] [at (document:node-start (layout:view-node window))])
    (for-each
      (lambda (action)
        (parameterize ([web:current-client client])
          ((tables:ref web:input-handlers "mouse") client
           `(("type" . "mouse") ("action" . ,action) ("button" . ,button) ("clicks" . 1) ("modifiers" . #())
             ("view" . ,(views:id s)) ("version" . ,(buffers:version layout:buffer))
             ("showing" . ,(views:shown-count s)) ("token" . ,at)
             ("keymaps" . ,(vector (mark-number status-line:keymap)))))))
      '("down" "click"))))

(define (mouse! keymaps button at)
  (let ([s layout:screen-view])
    (for-each
      (lambda (action)
        (parameterize ([web:current-client client])
          ((tables:ref web:input-handlers "mouse") client
           `(("token" . ,at) ("type" . "mouse") ("action" . ,action) ("button" . ,button) ("clicks" . 1)
             ("modifiers" . #()) ("view" . ,(views:id s)) ("version" . ,(buffers:version layout:buffer))
             ("showing" . ,(views:shown-count s)) ("keymaps" . ,(list->vector (map mark-number keymaps)))))))
      '("down" "click"))))

(define (numbers-after text needle)
  (let loop ([from 0] [acc '()])
    (let ([i (search text needle from)])
      (if i
          (let digits ([j (+ i (string-length needle))] [k 0])
            (if (char-numeric? (string-ref text j))
                (digits (+ j 1) (+ (* k 10) (- (char->integer (string-ref text j)) 48)))
                (loop j (cons k acc))))
          (reverse acc)))))

(define (strip-rest! focus)
  (let ([html (html->string (layout:screen client))])
    ((tables:ref web:input-handlers "scroller") client
     `(("type" . "scroller") ("scroller" . ,(car (numbers-after html "data-scroller=\"")))
       ("placement" . ,(car (numbers-after html "data-placement=\""))) ("report" . 1)
       ("items" . ,(vector focus)) ("whole" . ,(vector focus)) ("settled" . #t)
       ("item" . ,focus) ("align" . "start") ("focus" . ,focus)))))

(define (place-kind v)
  (let* ([html (html->string (views:draw v client))] [key "data-place-kind=\""] [i (search html key 0)]
         [from (+ i (string-length key))])
    (substring html from (search html "\"" from))))

(define (enclosing v) (document:enclosing (buffers:document layout:buffer) (document:node-start (layout:view-node v))))

(import (console))
