(import (tuna) (tuna plugins) (web) (keys) (commands) (document) (buffers) (views) (modes) (haml) (files attributes))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin editing)
(use-plugin echo-area)
(use-plugin minibuffer)
(use-plugin completion)
(use-plugin files)
(use-plugin file-picker)
(use-plugin undo)
(use-plugin undo-log)
(use-plugin kill-ring)
(use-plugin folder-listing)

(define client (web:add-client! 1))

(define (in-client thunk)
  (parameterize ([web:current-client client])
    (views:call-with-view (layout:selected-view) thunk)))

(define (press! . keys)
  (for-each
    (lambda (key)
      (parameterize ([web:current-client client])
        (views:call-with-view (layout:selected-view) (lambda () (keys:press! client key)))))
    keys))

(define (settle) (sleep-for 0.1))

(define (wait-until done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 500))
      (sleep-for 0.01)
      (loop (+ n 1)))))

(define (view) (layout:selected-view))

(define home (getenv "HOME"))

(define (at path) (string-append home "/" path))

(define (touch! path . text)
  (let ([path (at path)])
    (let loop ([folder (path-parent path)])
      (unless (file-exists? folder)
        (loop (path-parent folder))
        (mkdir folder)))
    (call-with-output-file path (lambda (p) (for-each (lambda (t) (display t p)) text)) 'replace)))

(define (folder! path) (mkdir (at path)))

(define c-symlink (begin (load-shared-object #f) (foreign-procedure "symlink" (string string) int)))

(define (symlink! target path) (c-symlink target (at path)))

(define (exists? path) (file-exists? (at path) #f))

(define (entries b)
  (let ([doc (buffers:document b)])
    (let loop ([p 0] [acc '()])
      (let ([t (document:token doc p)])
        (cond
          [(eof-object? t) (reverse acc)]
          [(and (document:node? t) (eq? (document:node-kind t) 'folder-listing:%entry)) (loop (+ p 1) (cons t acc))]
          [else (loop (+ p 1) acc)])))))

(define (entry-name e) (path-last (folder-listing:entry-path e)))

(define (listing-lines b)
  (map (lambda (e)
         (let ([m (folder-listing:entry-mark e)])
           (string-append (if m (string m) " ") " " (entry-name e))))
       (entries b)))

(define (goto name)
  (let ([e (find (lambda (e) (equal? (entry-name e) name)) (entries (views:buffer (view))))])
    (views:set-point! (view) (+ 1 (document:node-start e)))))

(define (show b) (for-each (lambda (l) (display l) (newline)) (listing-lines b)))

(define (point-name)
  (let ([e (folder-listing:entry-at (view))])
    (and e (path-last (folder-listing:entry-path e)))))

(define (message) (echo-area:current-message))

(define asked '())
(define (answer reply) (lambda (question . folder) (set! asked (cons question asked)) reply))
(define (questions) (let ([q (reverse asked)]) (set! asked '()) q))

(define (mouse-in! v action place . fields)
  (parameterize ([web:current-client client])
    ((table-ref web:input-handlers "mouse") client
     (append fields
             `(("type" . "mouse") ("action" . ,action) ("button" . 1) ("clicks" . 1) ("modifiers" . #())
               ("view" . ,(views:id v)) ("version" . ,(buffers:version (views:buffer v)))
               ("showing" . ,(views:shown-count v)) ("report" . 1)
               ,@place)))))

(define (click-name! name)
  (let* ([v (view)] [e (find (lambda (e) (equal? (entry-name e) name)) (entries (views:buffer v)))]
         [place `(("at" . ,(+ 1 (document:node-start e))) ("count" . 0)
                  ("keymaps" . ,(vector (views:keymap-mark folder-listing:name-keymap))))])
    (mouse-in! v "down" place)
    (mouse-in! v "click" place)))

(define (header-link folder)
  (let ([doc (buffers:document (views:buffer (view)))])
    (let loop ([p 0])
      (let ([t (document:token doc p)])
        (cond
          [(eof-object? t) #f]
          [(and (document:node? t) (equal? (document:node-attribute t 'path #f) folder)) t]
          [else (loop (+ p 1))])))))

(define (shown)
  (map (lambda (v) (list (buffers:name (views:buffer v)) (eq? v (view))))
       (filter (lambda (v) (not (buffers:internal-name? (buffers:name (views:buffer v))))) (layout:views))))

(define (contains? s sub)
  (let loop ([i 0])
    (and (<= (+ i (string-length sub)) (string-length s))
         (or (string=? (substring s i (+ i (string-length sub))) sub) (loop (+ i 1))))))

(define (drawn) (html->string (views:draw (view) client)))

(define (drawn-has? . subs) (map (lambda (sub) (contains? (drawn) sub)) subs))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))
(import (console))
