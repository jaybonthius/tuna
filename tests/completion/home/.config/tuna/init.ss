(import (tuna) (tuna plugins) (document) (haml) (web))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin editing)
(use-plugin echo-area)
(use-plugin undo)
(use-plugin modes)
(use-plugin python)
(use-plugin minibuffer)
(use-plugin completion
  (config
    (set-option! completion:styles (list completion:any-order))
    (table-set! completion:category-styles completion:file-category (list completion:partial))))
(use-plugin ui)
(use-plugin layout-float)
(use-plugin completion-list
  (config
    (set-option! completion-list:rows 15)))
(use-plugin completion-popup
  (config
    (add-hook! python:mode-hook
      (lambda () (set-option-local! completion-popup:auto-delay 0.1)))))
(use-plugin files)
(use-plugin file-picker)
(use-plugin buffer-picker)
(use-plugin command-picker)
(use-plugin line-picker
  (config
    (keys:bind! keys:global "C-s" line-picker:line)))
(use-plugin grep)

(jobs:define-worker (notes-files directory emit)
  (emit (list->vector
          (map (lambda (name) (cons name (cons (string-append directory "/" name) 1)))
               (directory-list directory)))))

(jobs:define-worker (one-at-a-time n emit)
  (do ([i 0 (+ i 1)]) ((= i n)) (emit (vector (format "item-~a" i)))))

(define (notes-source view)
  (completion:source
    (job notes-files (string-append (getenv "HOME") "/notes"))
    (category completion:location-category)
    (title "Notes")))

(set-option! buffer-picker:sources (list buffer-picker:buffers notes-source))
(use-plugin words)
(use-plugin completion-annotations
  (config
    (define (annotate-word session)
      (lambda (word) (list (number->string (string-length word)))))
    (table-set! completion:annotators words:word-category annotate-word)))

(define client (web:add-client! 1))

(define other-client (web:add-client! 2))

(define (press-in! c . keys)
  (for-each
    (lambda (key)
      (parameterize ([web:current-client c])
        (views:call-with-view (layout:selected-view) (lambda () (keys:press! c key)))))
    keys))

(define (press! . keys) (apply press-in! client keys))

(define (type! text)
  (for-each (lambda (c) (press! (if (char=? c #\space) "SPC" (string c)))) (string->list text)))

(define (in-client thunk)
  (parameterize ([web:current-client client])
    (views:call-with-view (layout:selected-view) thunk)))

;; A command's prompt pauses its task, so tests run it in a task of its
;; own and wait for the prompt.
(define (start! thunk)
  (let ([t (spawn-task (lambda () (in-client thunk)))])
    (sleep-for 0.05)
    t))

(define (result t)
  (wait-until (lambda () (task-done? t)))
  (if (task-done? t)
      (guard (c [#t (list 'raised (if (message-condition? c) (condition-message c) c))])
        (join-task t))
      'waiting))

(define (wait-until done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 500))
      (sleep-for 0.01)
      (loop (+ n 1)))))

(define (view) (layout:selected-view))

(define (text b) (document:text (buffers:document b)))

(define minibuf (buffers:find " *Minibuf*"))

(define (datums b) (document:datums (buffers:document b)))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))
(define (session) (in-client completion:current-session))

(define (mouse-in! v action place)
  (parameterize ([web:current-client client])
    ((table-ref web:input-handlers "mouse") client
     (append place
             `(("type" . "mouse") ("action" . ,action) ("button" . 1) ("clicks" . 1) ("modifiers" . #())
               ("view" . ,(views:id v)) ("version" . ,(buffers:version (views:buffer v)))
               ("showing" . ,(views:shown-count v)) ("report" . 1))))))

(define (click-token! v at)
  (mouse-in! v "down" `(("token" . ,at)))
  (mouse-in! v "click" `(("token" . ,at))))

(define (list-view)
  (let ([b (find (lambda (b) (let ([n (buffers:name b)]) (and (> (string-length n) 12) (string=? (substring n 0 12) " *Completion")))) (buffers:all))])
    (and b (car (views:showing b)))))

(define (row-position v n)
  (let ([doc (buffers:document (views:buffer v))])
    (let loop ([p 0] [k 0])
      (let ([t (document:token doc p)])
        (cond
          [(eof-object? t) #f]
          [(and (document:node? t) (eq? (document:node-kind t) 'ui:%list-row)) (if (= k n) p (loop (+ p 1) (+ k 1)))]
          [else (loop (+ p 1) k)])))))

;; A view's own element carries a placement number that differs from run
;; to run, so tests compare what it draws inside.
(define (lines-html v)
  (let* ([s (html->string (views:draw v client))] [open "<div class=\"view-lines\">"])
    (let loop ([i 0])
      (cond
        [(> (+ i (string-length open)) (string-length s)) s]
        [(string=? (substring s i (+ i (string-length open))) open) (substring s i (string-length s))]
        [else (loop (+ i 1))]))))

(define (prompt) (minibuffer:current-prompt))

(define (input) (minibuffer:input (prompt)))

;; A popup's anchor number differs from run to run.
(define (popups)
  (let ([doc (buffers:document layout:popups-buffer)])
    (let loop ([p 0] [acc '()])
      (if (= p (document:length doc))
          (reverse acc)
          (let ([t (document:token doc p)])
            (loop (+ p 1)
                  (if (and (document:node? t) (document:atom? t))
                      (cons (list (document:node-attribute t 'buffer) (document:node-attribute t 'width) (document:node-attribute t 'height)) acc)
                      acc)))))))

(define (wait-matches s) (wait-until (lambda () (not (completion:session-busy? s)))))

(define (match-list s) (let ([ms (completion:session-matches s)]) (do ([k (- (completion:matches-count ms) 1) (- k 1)] [acc '() (cons (completion:matches-ref ms k) acc)]) ((< k 0) acc))))

(define (rows s) (map (lambda (m) (cons (completion:text s m) (completion:annotation s m))) (match-list s)))

(define (texts s) (map (lambda (m) (completion:text s m)) (match-list s)))

(define (selected-text s) (let ([m (completion:selected s)]) (and m (completion:text s m))))

(import (console))
