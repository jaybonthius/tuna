(import (tuna) (testing) (tuna plugins) (document) (haml) (web) (disk) (layout-split) (syntax))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin editing)
(use-plugin echo-area)
(use-plugin undo)
(use-plugin files)
(use-plugin jump-history)
(use-plugin modes)
(use-plugin auto-mode)
(use-plugin prog)
(use-plugin python)
(use-plugin syntax-highlighting)
(use-plugin chez-scheme)
(use-plugin fill)
(use-plugin view)
(use-plugin minibuffer)
(use-plugin completion)
(use-plugin completion-list)
(use-plugin completion-popup)
(use-plugin command-picker)
(use-plugin status-line)
(use-plugin help)
(use-plugin occur)
(use-plugin dired)
(use-plugin rainbow-delimiters)
(use-plugin diagnostics)
(use-plugin diagnostics-list)
(use-plugin docs-at-point)
(use-plugin docs-at-point-display)
(use-plugin terminal)
(use-plugin lsp)
(use-plugin runs)
(use-plugin shell-commands)
(use-plugin jsonrpc)
(use-plugin ui)
(use-plugin pi-chat)

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
(define (start! . keys)
  (let ([t (spawn-task (lambda () (in-client (lambda () (apply press! keys)))))])
    (sleep-for 0.05)
    t))

(define (result t)
  (testing:wait-until (lambda () (task-done? t)))
  (if (task-done? t)
      (guard (c [#t (list 'raised (if (message-condition? c) (condition-message c) c))])
        (join-task t))
      'waiting))

(define (result-now t) (if (task-done? t) (result t) 'waiting))

(define (view) (layout:selected-view))

(define (text b) (document:text (buffers:document b)))

(define (local option b) (buffers:with-buffer b (option)))

(define (session) (in-client completion:current-session))

(define (prompt) (minibuffer:current-prompt))

(define (input) (minibuffer:input (prompt)))

(define (question) (minibuffer:question (prompt)))

(define (wait-matches s) (testing:wait-until (lambda () (not (completion:session-busy? s)))))

(define (match-list s)
  (wait-matches s)
  (let ([ms (completion:session-matches s)])
    (do ([k (- (completion:matches-count ms) 1) (- k 1)] [acc '() (cons (completion:matches-ref ms k) acc)]) ((< k 0) acc))))

(define (texts s) (map (lambda (m) (completion:text s m)) (match-list s)))

(define (annotation-text s m) (apply string-append (map (lambda (c) (if (pair? c) (cdr c) c)) (completion:annotation s m))))

(define (rows s) (map (lambda (m) (cons (completion:text s m) (annotation-text s m))) (match-list s)))

(define (annotated s) (filter (lambda (row) (not (string=? (cdr row) ""))) (rows s)))

(define (selected-text s) (let ([m (completion:selected s)]) (and m (completion:text s m))))

(define (echo) (echo-area:current-message))

(define minibuf (buffers:find " *Minibuf*"))

(define (search s sub from)
  (let loop ([i from])
    (cond
      [(> (+ i (string-length sub)) (string-length s)) #f]
      [(string=? (substring s i (+ i (string-length sub))) sub) i]
      [else (loop (+ i 1))])))

(define (between s open close)
  (let ([i (search s open 0)])
    (and i (let ([j (search s close (+ i (string-length open)))])
             (and j (substring s i (+ j (string-length close))))))))

(define (bracket)
  (between (html->string (views:draw (minibuffer:prompt-view (prompt)) client)) "<span class=\"minibuffer-message\"" "</span>"))

;; Keymaps print as their whole tables, so tests name the ones they know.
(define known-keymaps '())

(define (know! . pairs)
  (let loop ([pairs pairs])
    (unless (null? pairs)
      (set! known-keymaps (cons (cons (car pairs) (cadr pairs)) known-keymaps))
      (loop (cddr pairs)))))

(define (active-keymaps)
  (fold-right (lambda (k acc) (let ([found (assq k known-keymaps)]) (if found (cons (cdr found) acc) acc)))
              '()
              (in-client (lambda () (keys:active-keymaps client)))))

(know! modes:fundamental-keymap 'modes:fundamental-keymap prog:keymap 'prog:keymap python:keymap 'python:keymap
       chez-scheme:keymap 'chez-scheme:keymap fill:keymap 'fill:keymap)

;; Highlighting runs in a job, so a test waits until a buffer's spans have
;; not changed for a while.
(define (spans-of b layer) (buffers:spans (buffers:layer b layer) 0 (document:length (buffers:document b))))

(define (settle b)
  (let loop ([n 0] [same 0] [last #f])
    (let ([now (list (spans-of b syntax-highlighting:faces) (spans-of b syntax:brackets))])
      (unless (or (= same 15) (= n 500))
        (sleep-for 0.02)
        (loop (+ n 1) (if (equal? now last) (+ same 1) 0) now)))))

(define (strip-tags s)
  (let loop ([cs (string->list s)] [in? #f] [acc '()])
    (cond
      [(null? cs) (list->string (reverse acc))]
      [(char=? (car cs) #\<) (loop (cdr cs) #t acc)]
      [(char=? (car cs) #\>) (loop (cdr cs) #f acc)]
      [in? (loop (cdr cs) #t acc)]
      [else (loop (cdr cs) #f (cons (car cs) acc))])))

(define (segment html name)
  (let ([i (search html (string-append "data-segment=\"" name "\"") 0)])
    (and i (let* ([open-end (search html ">" i)]
                  [next (or (search html "data-segment=\"" open-end) (search html "</footer>" open-end))])
             (strip-tags (substring html (+ open-end 1) next))))))

(define (screen-modes c)
  (let ([s (html->string (layout:screen c))])
    (let loop ([from 0] [acc '()])
      (let ([i (search s "<footer class=\"status-line\"" from)])
        (if i
            (let* ([e (search s "</footer>" i)] [footer (substring s i (+ e 9))])
              (loop e (cons (list (segment footer "status-line:major-mode") (segment footer "status-line:minor-modes")) acc)))
            (reverse acc))))))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c)
                          (if (and (format-condition? c) (irritants-condition? c))
                              (apply format (condition-message c) (condition-irritants c))
                              (condition-message c))
                          c))])
    (thunk)))
(import (console))
