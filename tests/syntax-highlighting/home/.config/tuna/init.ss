(import (hooks) (options) (tables) (timers))
(import (tuna) (testing) (document) (disk))
(use-plugin modes)
(use-plugin views)
(use-plugin files)
(use-plugin auto-mode)
;; Loaded, not imported, so its unload in a test stays an unload.
(load-module! '(marks))

(define (marked name content mode)
  (let ([b (buffers:make name content)])
    (modes:set-major-mode mode b)
    b))

(define (spans-of b type)
  (buffers:spans (buffers:layer b type) 0 (document:length (buffers:document b))))

(define (all-spans b)
  (map (lambda (layer) (buffers:spans layer 0 (document:length (buffers:document b)))) (buffers:layers b)))

;; Highlighting runs in a job, so a test waits until the spans have not
;; changed for a while.
(define (settle b)
  (let loop ([n 0] [same 0] [last #f])
    (let ([now (list (spans-of b syntax-highlighting:faces) (spans-of b marks:parens))])
      (unless (or (= same 15) (= n 500))
        (timers:sleep 0.02)
        (loop (+ n 1) (if (equal? now last) (+ same 1) 0) now)))))

(define (faces b)
  (settle b)
  (map (lambda (s) (list (document:text (buffers:document b) (car s) (cadr s)) (cdr (assq 'face (caddr s)))))
       (spans-of b syntax-highlighting:faces)))

(define (parens b)
  (settle b)
  (map (lambda (s) (document:text (buffers:document b) (car s) (cadr s))) (spans-of b marks:parens)))

(define %job-events '())
(define (note-job! event job)
  (when (member (format "~a" job) '("#<job %marks>" "#<job %raising>" "#<job %pieces>"))
    (set! %job-events (cons (list event job) %job-events))))
(advice-add! jobs:start
  (lambda (start . args)
    (let ([job (apply start args)])
      (note-job! 'start job)
      job)))
(advice-add! jobs:stop!
  (lambda (stop job)
    (note-job! 'stop job)
    (stop job)))

(define (job-events)
  (let ([found (reverse %job-events)])
    (set! %job-events '())
    found))

(define (pieces-buffer name content)
  (disk:folder! (string-append "~/gates/" name))
  (marked name content marks:pieces))

(define (open-gate! b n)
  (disk:write-text! (string-append "~/gates/" (buffers:name b) "/gate-" (number->string n)) ""))

(disk:folder! "~/gates")
(import (console))
