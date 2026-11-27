#!tuna
(import (options) (ask) (document) (buffers) (files) (layout) (views))

(define (home-path name) (string-append (getenv "HOME") "/" name))

;; A file, since what is noted as Tuna exits must outlive the process.
(define (note! text)
  (call-with-output-file (home-path "events") (lambda (p) (put-string p text) (newline p)) 'append))

;; The selected view has no buffer for a moment while the layout starts.
(define (shown)
  (let* ([view (layout:selected-view)] [b (and view (views:buffer view))])
    (and b (list (buffers:name b) (document:line (buffers:document b) (views:point view))))))

(define (showing? name) (let ([s (shown)]) (and s (equal? name (car s)))))

(define (file-names) (list-sort string<? (map buffers:name (files:buffers))))

(define (noting reply) (lambda (question) (note! (string-append "asked: " question)) reply))

;; Each report is noted as data rather than written, so the test knows
;; every report the start made, and standard error holds only the rest.
(advice-add! report
  (lambda (next c)
    (note! (string-append "reported: " (if (message-condition? c) (condition-message c) "?")))))
(options:set! ask:message-writer (lambda (text) (void)))
(options:set! ask:yes-or-no-reader (noting #t))
(options:set! ask:y-or-n-reader (noting #t))
