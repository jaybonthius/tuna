(import (tuna) (tuna plugins))

;; Transcripts run at once, so each listens on a port of its own.
(define test-port
  (cdr (assoc (getenv "TRANSCRIPT")
              '(("examples" . 19301) ("input" . 19302) ("screens" . 19303) ("clients" . 19304)
                ("server" . 19305) ("files" . 19306) ("races" . 19307) ("reload" . 19308)))))

(use-plugin web
  (config
    (set-option! web:port test-port)))

(import (haml) (http))
(http:use-port! (lambda () (web:port)))

(define log '())
(define (note! x) (set! log (cons x log)))
(define (taken!)
  (let ([l (reverse log)])
    (set! log '())
    l))

(define (wait-until done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 500))
      (sleep-for 0.01)
      (loop (+ n 1)))))

(import (console))
