(import (tuna) (tuna plugins) (document) (haml) (web))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin editing)
(use-plugin echo-area)
(use-plugin minibuffer)
(use-plugin completion)
(use-plugin completion-list)
(use-plugin files)
(use-plugin file-picker)
(use-plugin buffer-picker)
(use-plugin line-picker)
(use-plugin grep)
(use-plugin folder-listing)
(use-plugin projects)
(use-plugin jump-history)
(use-plugin diagnostics)
(use-plugin diagnostic-picker)
(use-plugin xref)

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

(define (result t)
  (wait-until (lambda () (task-done? t)))
  (if (task-done? t)
      (guard (c [#t (list 'raised (if (message-condition? c) (condition-message c) c))])
        (join-task t))
      'waiting))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))

(define (view) (layout:selected-view))

(define (session) (in-client completion:current-session))

(define (wait-matches s) (wait-until (lambda () (not (completion:session-busy? s)))))

(define (match-list s)
  (let ([ms (completion:session-matches s)])
    (do ([k (- (completion:matches-count ms) 1) (- k 1)] [acc '() (cons (completion:matches-ref ms k) acc)]) ((< k 0) acc))))

(define (texts s) (map (lambda (m) (completion:text s m)) (match-list s)))

;; Where the selected view is: its buffer's name and the line of point.
(define (here)
  (let* ([v (view)] [b (views:buffer v)])
    (list (buffers:name b) (document:line (buffers:document b) (views:point v)))))

(define (places)
  (map (lambda (p) (list (buffers:name (car p)) (document:line (buffers:document (car p)) (cdr p)))) (jump-history:places)))

(define code (string-append (getenv "HOME") "/code"))

;; A backend over the files under ~/code: "def NAME" lines define NAME,
;; and any line holding NAME uses it.
(define (code-files)
  (list (string-append code "/defs.txt") (string-append code "/sub/twice.txt") (string-append code "/uses.txt")))

(define (file-lines path)
  (let ([text (call-with-input-file path get-string-all)])
    (let loop ([i 0] [start 0] [n 1] [acc '()])
      (cond
        [(= i (string-length text)) (reverse acc)]
        [(char=? (string-ref text i) #\newline) (loop (+ i 1) (+ i 1) (+ n 1) (cons (cons n (substring text start i)) acc))]
        [else (loop (+ i 1) start n acc)]))))

(define (contains? s part)
  (let loop ([i 0])
    (and (<= (+ i (string-length part)) (string-length s))
         (or (string=? (substring s i (+ i (string-length part))) part) (loop (+ i 1))))))

(define (items-where keep)
  (apply append
    (map (lambda (path)
           (fold-right (lambda (l acc) (if (keep (cdr l)) (cons (xref:make-item (cdr l) path (car l) 0) acc) acc))
                       '() (file-lines path)))
         (code-files))))

(define asked '())
(define answered '())

(define words-backend
  (xref:backend "words"
    [identifier-at-point
     (lambda (v)
       (let-values ([(s e) (syntax:symbol-bounds (views:buffer v) (views:point v))])
         (and s (< s e) (document:text (buffers:document (views:buffer v)) s e))))]
    [identifiers (lambda (input) (filter (lambda (n) (contains? n input)) '("total" "average" "tally")))]
    [definitions (lambda (name) (items-where (lambda (line) (string=? line (string-append "def " name)))))]
    [references (lambda (name) (items-where (lambda (line) (and (contains? line name) (not (contains? line "def "))))))]
    [apropos
     (lambda (pattern)
       (set! asked (cons pattern asked))
       (sleep-for 0.05)
       (set! answered (cons pattern answered))
       (items-where (lambda (line) (and (contains? line "def ") (contains? line pattern)))))]))

(define (code-backend view) words-backend)

(add-hook! files:after-visit
  (lambda (b)
    (when (contains? (or (files:path b) "") "/code/")
      (buffers:with-buffer b (add-local-hook! xref:backends code-backend)))))

(define notes (files:visit (string-append (getenv "HOME") "/notes/a.txt")))
(layout:switch-to-buffer notes)
(set-idle! #t)
(import (console))
