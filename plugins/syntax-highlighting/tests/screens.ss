(import (tuna) (test) (test-user) (modes) (buffers) (views) (layout) (web) (haml) (options) (syntax-highlighting)
        (syntax-highlighting-test) (syntax-highlighting-test marks))

(define (faces-become b expected) (syntax-highlighting-test/marks:faces-become b expected))

(define log '())

(define (note! entry) (set! log (cons entry log)))

(define (comment-faces screen)
  (length (filter (lambda (e) (equal? "comment" (test-user:element-attribute e "data-face")))
                  (test-user:elements-with (html->sxml screen) "data-face"))))

(define (log-spans set layer start end spans . version)
  (when (eq? layer (buffers:layer b syntax-highlighting:faces))
    (note! (list 'spans (length spans))))
  (apply set layer start end spans version))

(define (log-screen send client screen title)
  (when (eq? client (test-user:client))
    (note! (list 'screen (comment-faces screen))))
  (send client screen title))

;; A batch may end with nothing new to draw, and then the same screen is
;; given again, so a screen repeated in a row counts once.
(define (logged thunk)
  (set! log '())
  (thunk)
  (test-user:settle)
  (let squeeze ([l (reverse log)])
    (cond
      [(or (null? l) (null? (cdr l))) l]
      [(and (equal? (car l) (cadr l)) (eq? (caar l) 'screen)) (squeeze (cdr l))]
      [else (cons (car l) (squeeze (cdr l)))])))

(define b (buffers:make "f.mk" "#a (b)\n"))

(advice-add! buffers:set-spans! log-spans)
(advice-add! web:send-screen! log-screen)

(test "faces turned off, and the spans of a job that stops, go before the batch's screens are drawn, when layout's end of batch wraps syntax-highlighting's"
  (views:set-buffer! (layout:selected-view) b)
  (modes:set-major-mode syntax-highlighting-test/marks:mode b)
  (faces-become b '(("#a" comment)))
  (test-user:settle)
  (check-equal? 1 (length (test-user:elements-with (test-user:screen) "data-face")))
  (check-equal? '((spans 0) (screen 0)) (logged (lambda () (buffers:with-buffer b (options:set-local! syntax-highlighting:mode #f)))))
  (check-equal? '((screen 0) (spans 1) (screen 1)) (logged (lambda () (buffers:with-buffer b (options:set-local! syntax-highlighting:mode #t)))))
  (check-equal? '((spans 0) (screen 0)) (logged (lambda () (modes:set-major-mode modes:fundamental b)))))

(test "the same when syntax-highlighting, loaded again after layout, wraps layout's end of batch"
  (unload-owner! (module-owner '(syntax-highlighting)))
  (load-module! '(syntax-highlighting-test marks))
  (modes:set-major-mode syntax-highlighting-test/marks:mode b)
  (faces-become b '(("#a" comment)))
  (test-user:settle)
  (check-equal? '((spans 0) (screen 0)) (logged (lambda () (buffers:with-buffer b (options:set-local! syntax-highlighting:mode #f)))))
  (buffers:with-buffer b (options:set-local! syntax-highlighting:mode #t))
  (faces-become b '(("#a" comment)))
  (test-user:settle)
  (check-equal? '((spans 0) (screen 0)) (logged (lambda () (modes:set-major-mode modes:fundamental b)))))
