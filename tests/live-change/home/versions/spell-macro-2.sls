#!tuna
(import (files))

(define (language) "en")

(define (dictionary-path)
  (string-append "/usr/share/words/" (language)))

(define %checked 0)

(define (checked) %checked)

(define (check path)
  (set! %checked (+ %checked 1))
  (display (string-append "checking " path " against " (dictionary-path))))

(define (log-save save! path)
  (display "[spell] ")
  (save! path))

(define-syntax with-words
  (syntax-rules ()
    [(_ e) (list 'v2 e)]))

(advice-add! files:save! log-save)
