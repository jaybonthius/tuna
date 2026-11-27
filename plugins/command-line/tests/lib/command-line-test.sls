#!tuna
(import (options) (document) (buffers) (layout) (views))

(options:define-option level 0 fixnum? "A setting that the tests' configurations and command lines both make.")

(define (home-path name) (string-append (getenv "HOME") "/" name))

(define (write-file! name text)
  (call-with-output-file (home-path name) (lambda (p) (put-string p text)) 'replace))

(define (lines-file! name count prefix)
  (write-file! name
    (apply string-append (map (lambda (i) (format "~a ~a\n" prefix (+ i 1))) (iota count)))))

;; The selected view has no buffer for a moment while the layout starts.
(define (shown)
  (let* ([view (layout:selected-view)] [b (and view (views:buffer view))])
    (and b (list (buffers:name b) (document:line (buffers:document b) (views:point view))))))

(define (showing? name) (let ([s (shown)]) (and s (equal? name (car s)))))
