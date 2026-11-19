(import (tuna) (tuna plugins) (web) (keys) (commands) (document) (buffers) (views) (modes) (haml))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin editing)
(use-plugin echo-area)
(use-plugin minibuffer)
(use-plugin completion)
(use-plugin files)
(use-plugin file-picker)
(use-plugin command-picker)
(use-plugin undo)
(use-plugin help
  (config
    (keys:bind! keys:global "C-c ?" help:describe-bindings)
    (table-set! layout:display-rules help:buffer? layout-split:display-below)))
(import (harpo))

(define client (web:add-client! 1))

(define (in-client thunk)
  (parameterize ([web:current-client client])
    (layout:call-with-frame (layout:frame client) thunk)))

(define (press! . keys)
  (for-each
    (lambda (key)
      (parameterize ([web:current-client client])
        (layout:call-with-frame (layout:frame client) (lambda () (keys:press! client key)))))
    keys))

;; A command that reads pauses its task, so tests start it in a task of
;; its own and wait for the read.
(define (start! . keys)
  (spawn-task (lambda () (apply press! keys)))
  (sleep-for 0.05))

(define (settle) (sleep-for 0.05))

(define (view) (layout:selected-view))

(define (shown)
  (map (lambda (v) (list (buffers:name (views:buffer v)) (eq? v (view))))
       (filter (lambda (v) (not (buffers:internal-name? (buffers:name (views:buffer v))))) (layout:views))))

(define (help-buffer) (buffers:find "*Help*"))

;; *Help* as text: a title as #, a heading as ##, a key in brackets and a
;; link in angle brackets.
(define (render d)
  (if (string? d)
      d
      (let ([inner (apply string-append (map render (cddr d)))])
        (case (car d)
          [(help:%title) (string-append "# " inner)]
          [(help:%heading) (string-append "## " inner)]
          [(help:%key) (string-append "[" inner "]")]
          [(help:%link) (string-append "<" inner ">")]
          [else inner]))))

(define (help-text) (render (car (document:datums (buffers:document (help-buffer))))))

(define (help) (display (help-text)))

(define (help-lines)
  (let loop ([chars (string->list (help-text))] [line '()] [acc '()])
    (cond
      [(null? chars) (reverse acc)]
      [(char=? (car chars) #\newline) (loop (cdr chars) '() (cons (list->string (reverse line)) acc))]
      [else (loop (cdr chars) (cons (car chars) line) acc)])))

(define (contains? s sub)
  (let loop ([i 0])
    (and (<= (+ i (string-length sub)) (string-length s))
         (or (string=? (substring s i (+ i (string-length sub))) sub) (loop (+ i 1))))))

(define (help-with . subs)
  (for-each (lambda (line) (when (exists (lambda (sub) (contains? line sub)) subs) (display line) (newline)))
            (help-lines)))

(define (outline) (help-with "#"))

(define (title)
  (let ([text (caddr (caddr (car (document:datums (buffers:document (help-buffer))))))])
    (substring text 0 (- (string-length text) 1))))

(define (message) (echo-area:current-message))

(define (help-view) (car (views:showing (help-buffer))))

(define (link-to name)
  (let ([doc (buffers:document (help-buffer))])
    (let loop ([p 0])
      (let ([t (document:token doc p)])
        (cond
          [(eof-object? t) #f]
          [(and (document:node? t) (eq? (document:node-kind t) 'help:%link)
                (eq? (document:node-attribute t 'name) name))
           p]
          [else (loop (+ p 1))])))))

(define (type! text) (apply press! (map string (string->list text))))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))
(import (console))
