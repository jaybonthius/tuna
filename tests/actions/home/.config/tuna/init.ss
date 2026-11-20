(import (tuna) (tuna plugins) (document) (web))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin editing)
(use-plugin echo-area)
(use-plugin undo)
(use-plugin modes)
(use-plugin minibuffer)
(use-plugin completion)
(use-plugin ui)
(use-plugin completion-list)
(use-plugin files)
(use-plugin file-picker)
(use-plugin buffer-picker)
(use-plugin command-picker)
(use-plugin help)
(use-plugin actions)
(use-plugin layout-float)
(use-plugin completion-popup)
(use-plugin chez-scheme)
(use-plugin chez-scheme-completion)
(use-plugin folder-listing)
(use-plugin shell-commands)

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

;; A command's prompt pauses its task, so tests run it in a task of its
;; own and wait for the prompt.
(define (start! thunk)
  (let ([t (spawn-task (lambda () (in-client thunk)))])
    (sleep-for 0.05)
    t))

(define (wait-until done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 500))
      (sleep-for 0.01)
      (loop (+ n 1)))))

;; An action's command reads its key in a task of its own, so a test
;; presses the key only once the read waits for it.
(define (act! . keys)
  (let ([t (start! (lambda () (apply press! keys)))])
    (wait-until (lambda () (or (task-done? t) (keys:reading client))))
    t))

(define (result t)
  (wait-until (lambda () (task-done? t)))
  (if (task-done? t)
      (guard (c [(quit-condition? c) 'quit]
                [#t (list 'raised (if (message-condition? c) (condition-message c) c))])
        (join-task t))
      'waiting))

(define (view) (layout:selected-view))

(define (session) (in-client completion:current-session))

(define (prompt) (minibuffer:current-prompt))

(define (input) (minibuffer:input (prompt)))

(define (wait-matches s) (wait-until (lambda () (not (completion:session-busy? s)))))

(define (match-list s)
  (let ([ms (completion:session-matches s)])
    (do ([k (- (completion:matches-count ms) 1) (- k 1)] [acc '() (cons (completion:matches-ref ms k) acc)])
        ((< k 0) acc))))

(define (texts s) (map (lambda (m) (completion:text s m)) (match-list s)))

(define (selected-text s) (let ([m (completion:selected s)]) (and m (completion:text s m))))

(define (names) (map buffers:name (remp (lambda (b) (buffers:internal-name? (buffers:name b))) (buffers:all))))

(define (text b) (document:text (buffers:document b) 0 (document:length (buffers:document b))))

(define (show! b) (views:set-buffer! (view) b) b)

(define (position-of b string offset)
  (let* ([t (text b)] [n (string-length string)])
    (let loop ([i 0])
      (if (string=? (substring t i (+ i n)) string)
          (document:position (buffers:document b) (+ i offset) (document:unit characters))
          (loop (+ i 1))))))

(define (at! b string offset) (views:set-point! (view) (position-of b string offset)))

(define (prompt-text) (text (views:buffer (minibuffer:prompt-view (prompt)))))

;; Highlighting finds a buffer's scope in a job, so a test waits until
;; the buffer's names have come.
(define (settle-names b)
  (wait-until (lambda () (not (eq? (chez-scheme:names b) (chez-scheme:repl-names)))))
  (sleep-for 0.05))

(define (help-title)
  (let* ([b (buffers:find "*Help*")] [t (and b (text b))])
    (and t (let loop ([i 0]) (if (or (= i (string-length t)) (char=? (string-ref t i) #\newline)) (substring t 0 i) (loop (+ i 1)))))))

(import (console))
