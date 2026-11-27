#!tuna
(import (buffers) (document) (views) (options) (ui) (files) (diagnostics) (test-user))

(define (text b) (document:text (buffers:document b)))

(define (mode! b on?) (buffers:with-buffer b (options:set-local! diagnostics:mode on?)))

(define (word b s)
  (let ([t (text b)])
    (let loop ([i 0])
      (if (string=? (substring t i (+ i (string-length s))) s) (+ i 1) (loop (+ i 1))))))

(define (mark b s severity message)
  (diagnostics:make-diagnostic (word b s) (+ (word b s) (string-length s)) severity message))

(define root (string-append (getenv "HOME") "/project"))

(define (write-file! name content)
  (let ([path (string-append root "/" name)])
    (when (file-exists? path) (delete-file path))
    (with-output-to-file path (lambda () (display content)))
    path))

(define (list-buffer name) (buffers:find (string-append "*Diagnostics " name "*")))

(define (list-view name) (car (views:showing (list-buffer name))))

(define (view-element v)
  (let ([id (number->string (views:id v))])
    (find (lambda (e) (equal? id (test-user:element-attribute e "data-view")))
          (test-user:elements-with (test-user:screen) "data-view"))))

(define (row-elements v) (test-user:elements (view-element v) "ui-row"))

(define (rows v)
  (test-user:settle)
  (map (lambda (row) (map test-user:element-text (test-user:elements row "ui-label"))) (row-elements v)))

(define (links v i) (test-user:elements-with (list-ref (row-elements v) i) "data-keymap"))

(define (selected v) (ui:selected-row (document:token (buffers:document (views:buffer v)) 0) v))

(define (pulsed? v)
  (test-user:settle)
  (exists (lambda (e) (equal? "pulse.highlight" (test-user:element-attribute e "data-face")))
          (test-user:elements-with (view-element v) "data-face")))

;; A window's counts are the only ones drawn, since a list's buffer has
;; diagnostics off.
(define (counts-element)
  (test-user:settle)
  (find (lambda (e) (pair? (test-user:elements e "diagnostics-list-counts")))
        (filter (lambda (e) (equal? "diagnostics-list:counts" (test-user:element-attribute e "data-segment")))
                (test-user:elements-with (test-user:screen) "data-segment"))))

(define (counts)
  (let ([e (counts-element)])
    (and e (test-user:element-text (car (test-user:elements e "diagnostics-list-counts"))))))

(define (count-faces)
  (map (lambda (e) (list (test-user:element-attribute e "data-face") (test-user:element-attribute e "data-count")))
       (test-user:elements-with (counts-element) "data-count")))
