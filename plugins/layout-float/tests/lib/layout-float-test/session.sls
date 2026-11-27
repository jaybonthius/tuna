#!tuna
;; Each start makes the buffers again, as a configuration would, since a
;; saved layout's views wait for buffers of their names.
(import (tuna) (buffers) (document) (layout))

(define (make-buffers!)
  (buffers:make "notes" "one\ntwo\nthree\n")
  (buffers:make "other" "other\n"))

(define (tree) (car (document:datums (buffers:document layout:buffer))))

(define (popups) (car (document:datums (buffers:document layout:popups-buffer))))

(define (expected-file) (string-append (getenv "HOME") "/expected"))

;; Layout makes the views of new atoms, and writes its saved data, when a
;; batch ends, and a file's forms run in one batch until something pauses
;; them.
(define (end-batch!)
  (suspend (lambda (resume) (spawn-task (lambda (restore) (resume void))))))
