#!tuna
(import (buffers) (document) (jobs) (modes) (test-runner))

(define (marked name content mode)
  (let ([b (buffers:make name content)])
    (modes:set-major-mode mode b)
    b))

(define (spans-of b type)
  (buffers:spans (buffers:layer b type) 0 (document:length (buffers:document b))))

(define (all-spans b)
  (map (lambda (layer) (buffers:spans layer 0 (document:length (buffers:document b)))) (buffers:layers b)))

(define %job-events '())

(define (%note-job! event job)
  (let ([name (format "~a" job)])
    (when (member name '("#<job %marks>" "#<job %raising>" "#<job %pieces>"))
      (set! %job-events (cons (list event (string->symbol (substring name 6 (- (string-length name) 1)))) %job-events)))))

(define (%start start . arguments)
  (let ([job (apply start arguments)])
    (%note-job! 'start job)
    job))

(define (%stop stop job)
  (%note-job! 'stop job)
  (stop job))

(define (job-events)
  (let ([found (reverse %job-events)])
    (set! %job-events '())
    found))

(define (reports-until count thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (thunk)
    (test-runner:wait-until (lambda () (>= (length reported) count)))
    (advice-remove! report keep)
    (map (lambda (c) (list (condition-who c) (condition-message c))) (reverse reported))))

(advice-add! jobs:start %start)
(advice-add! jobs:stop! %stop)
