(import (tuna) (tuna plugins) (document) (web))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin editing)
(use-plugin echo-area)
(use-plugin modes)
(use-plugin minibuffer)
(use-plugin completion)
(use-plugin ui)
(use-plugin layout-float)
(use-plugin completion-popup)
(use-plugin completion-annotations)
(use-plugin files)
(use-plugin chez-scheme)
(use-plugin chez-scheme-completion)
(use-plugin help)
(import (zeppo))

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

(define (view) (layout:selected-view))

(define (text b) (document:text (buffers:document b)))

(define (wait-until done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 500))
      (sleep-for 0.01)
      (loop (+ n 1)))))

;; Highlighting finds a buffer's scope in a job, so a test waits until
;; the buffer's names have come.
(define (settle-names b)
  (wait-until (lambda () (not (eq? (chez-scheme:names b) (chez-scheme:repl-names)))))
  (sleep-for 0.05))

(define (show-file! path)
  (let ([b (files:visit path)])
    (views:set-buffer! (view) b)
    b))

(define (session) (in-client completion:current-session))

(define (match-list s) (let ([ms (completion:session-matches s)]) (do ([k (- (completion:matches-count ms) 1) (- k 1)] [acc '() (cons (completion:matches-ref ms k) acc)]) ((< k 0) acc))))

(define (rows s)
  (map (lambda (m)
         (list (completion:text s m) (completion:value s m) (completion:category s m)
               (map (lambda (c) (if (pair? c) (cdr c) c)) (completion:annotation s m))))
       (match-list s)))

(define (row-of s text) (assoc text (rows s)))

(define (complete! . keys)
  (apply press! keys)
  (press! "C-M-i")
  (wait-until (lambda () (let ([s (session)]) (and s (not (completion:session-busy? s)))))))

;; A read pauses its task, so a test runs it in a task of its own.
(define (start! . keys)
  (spawn-task (lambda () (apply press! keys)))
  (sleep-for 0.05))

(define (prompt-input) (minibuffer:input (minibuffer:current-prompt)))

(define (help-title)
  (let ([b (buffers:find "*Help*")])
    (and b
         (let ([text (caddr (caddr (car (document:datums (buffers:document b)))))])
           (substring text 0 (- (string-length text) 1))))))

(define (raised thunk)
  (guard (c [#t (list (if (who-condition? c) (condition-who c) 'none)
                      (if (message-condition? c) (condition-message c) c))])
    (thunk)))
(import (console))
