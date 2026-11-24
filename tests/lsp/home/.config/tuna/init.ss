(import (tuna) (testing) (tuna plugins) (web) (keys) (views) (buffers) (document) (modes) (json))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin editing)
(use-plugin echo-area)
(use-plugin minibuffer)
(use-plugin undo)
(use-plugin files)
(use-plugin completion)
(use-plugin completion-list)
(use-plugin layout-float)
(use-plugin completion-popup)
(use-plugin auto-mode)
(use-plugin docs-at-point
  (config
    (set-option! docs-at-point:delay 0.05)))
(use-plugin docs-at-point-display)
(use-plugin lsp
  (config
    (set-option! lsp:send-changes-delay 0.05 lsp:highlight-delay 0.05)
    (keys:bind! keys:global "C-c a" lsp:code-actions)
    (keys:bind! keys:global "C-c r" lsp:rename)
    (keys:bind! keys:global "C-c s" lsp:start)))

(define client (web:add-client! 1))

(define (press! . keys)
  (for-each
    (lambda (key)
      (parameterize ([web:current-client client])
        (views:call-with-view (layout:selected-view) (lambda () (keys:press! client key)))))
    keys))

(define (type! text)
  (for-each (lambda (c) (press! (case c [(#\space) "SPC"] [(#\newline) "RET"] [else (string c)]))) (string->list text)))

(define (in-client thunk)
  (parameterize ([web:current-client client])
    (views:call-with-view (layout:selected-view) thunk)))

;; A command's prompt pauses its task, so tests run it in a task of its
;; own.
(define (start! thunk)
  (let ([t (spawn-task (lambda () (in-client thunk)))])
    (sleep-for 0.05)
    t))


(define (result t)
  (testing:wait-until (lambda () (task-done? t)))
  (if (task-done? t)
      (guard (c [#t (list 'raised (if (message-condition? c) (condition-message c) c))])
        (join-task t))
      'waiting))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))

(define (view) (layout:selected-view))

(define (mouse! view . fields)
  (parameterize ([web:current-client client])
    ((table-ref web:input-handlers "mouse") client
     (append fields
             `(("type" . "mouse") ("clicks" . 1) ("modifiers" . #())
               ("view" . ,(views:id view)) ("version" . ,(buffers:version (views:buffer view)))
               ("showing" . ,(views:shown-count view)))))))

(define (session) (in-client completion:current-session))

(define (match-list s)
  (let ([ms (completion:session-matches s)])
    (do ([k (- (completion:matches-count ms) 1) (- k 1)] [acc '() (cons (completion:matches-ref ms k) acc)]) ((< k 0) acc))))

(define (texts s) (map (lambda (m) (completion:text s m)) (match-list s)))

(define (wait-matches s) (testing:wait-until (lambda () (not (completion:session-busy? s)))))

(define (text b) (document:text (buffers:document b)))

(define said '())
(set-option! ask:message-writer (lambda (s) (set! said (cons s said))))
(define (take-said!) (let ([s (reverse said)]) (set! said '()) s))

(define tuna-program (car (command-line)))
(define libraries (string-append (path-parent tuna-program) "/libraries"))
(define home (getenv "HOME"))

;; A fake server's answers are a file it reads before each message.
(define (config-of name) (format "~a/~a.config" home name))
(define (record-of name) (format "~a/~a.record" home name))

(define (configure! name . settings)
  (with-output-to-file (config-of name) (lambda () (write settings)) 'replace))

(define (fake-command name)
  (list tuna-program "--script" (string-append home "/fake-server.ss") libraries (config-of name) (record-of name)))

;; The messages a fake server has read, as JSON, oldest first. The
;; server may be writing a long message as the record is read, so text
;; after the last line break is not yet a message.
(define (received name)
  (if (file-exists? (record-of name))
      (let ([all (call-with-input-file (record-of name) get-string-all)])
        (let loop ([start 0] [i 0] [acc '()])
          (cond
            [(or (eof-object? all) (= i (string-length all))) (reverse acc)]
            [(char=? (string-ref all i) #\newline) (loop (+ i 1) (+ i 1) (cons (string->json (substring all start i)) acc))]
            [else (loop start (+ i 1) acc)])))
      '()))

(define (ref v . keys)
  (let loop ([v v] [keys keys])
    (cond
      [(null? keys) v]
      [(and (list? v) (assoc (car keys) v)) => (lambda (p) (loop (cdr p) (cdr keys)))]
      [(and (vector? v) (fixnum? (car keys))) (loop (vector-ref v (car keys)) (cdr keys))]
      [else #f])))

(define (methods name) (map (lambda (m) (ref m "method")) (received name)))

(define (of-method name method) (filter (lambda (m) (equal? (ref m "method") method)) (received name)))

(define (last-of name method) (let ([ms (of-method name method)]) (and (pair? ms) (list-ref ms (- (length ms) 1)))))

(define (wait-for name method . count)
  (let ([n (if (null? count) 1 (car count))])
    (testing:wait-until (lambda () (>= (length (of-method name method)) n)))))

(define-table fake-keymap)
(define-hook fake-mode-hook)
(modes:define-major-mode fake-mode (keymap fake-keymap) (hook fake-mode-hook) (language "fakelang"))
(table-set! auto-mode:file-names "fk" fake-mode)

(define (write-file! path content)
  (let ([dir (path-parent path)]) (unless (file-exists? dir) (system (format "mkdir -p '~a'" dir))))
  (with-output-to-file path (lambda () (display content)) 'replace))

(define (visit! path)
  (let ([b (files:visit path)])
    (in-client (lambda () (layout:switch-to-buffer b)))
    b))

(define project (format "~a/project" home))
(system (format "mkdir -p '~a/.git'" project))

(set-idle! #t)
(import (console))
