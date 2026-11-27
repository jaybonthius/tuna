(import (timers))
(import (tuna))
(use-plugin layout)
(use-plugin layout-split)
(use-plugin editing)
(use-plugin echo-area)
(use-plugin minibuffer)
(use-plugin completion)
(use-plugin files)
(use-plugin chez-scheme)
(use-plugin chez-scheme-completion)
(use-plugin eval)

(define (flag? name) (file-exists? (string-append (getenv "HOME") "/" name)))

(when (flag? "fail") (car 1))

(when (flag? "warn") (warning 'init "only a warning"))

(define after-fail 'ran)

(define (evaluate! b)
  (let ([t (spawn-task (lambda (restore) (commands:run eval:buffer b)))])
    (let loop ([n 0])
      (unless (or (eq? (task-state t) 'done) (= n 500))
        (timers:sleep 0.01)
        (loop (+ n 1))))
    (eq? (task-state t) 'done)))

(define (flag! name) (with-output-to-file (string-append (getenv "HOME") "/" name) void))

(define (unflag! name) (delete-file (string-append (getenv "HOME") "/" name)) (void))
(import (console))
