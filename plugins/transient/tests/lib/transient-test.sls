#!tuna
(import (views) (buffers) (test-user))

(define (%first element class)
  (let ([found (test-user:elements element class)])
    (and (pair? found) (car found))))

(define (%entry e)
  (let ([argument (%first e "transient-argument")])
    (append (list (test-user:element-text (%first e "transient-key")) (test-user:element-text (%first e "ui-label")))
            (if argument
                (list (string-append (if (equal? "true" (test-user:element-attribute e "aria-pressed")) "*" "")
                                     (test-user:element-text argument)))
                '()))))

(define (%group g)
  (let ([heading (%first g "transient-heading")] [entries (map %entry (test-user:elements g "transient-entry"))])
    (if heading (cons (test-user:element-text heading) entries) entries)))

(define menu
  (case-lambda
    [() (menu (test-user:client))]
    [(client)
     (let ([shown (%first (test-user:screen client) "transient-menu")])
       (and shown
            (let ([title (%first shown "transient-title")] [groups (map %group (test-user:elements shown "transient-group"))])
              (if title (cons (test-user:element-text title) groups) groups))))]))

(define (popup-view)
  (let ([b (buffers:find " *transient*")])
    (and b (let ([vs (views:showing b)]) (and (pair? vs) (car vs))))))

(define (%entry-key client key)
  (find (lambda (k) (equal? key (test-user:element-text k))) (test-user:elements (test-user:screen client) "transient-key")))

(define click-entry!
  (case-lambda
    [(key) (click-entry! (test-user:client) key "<mouse-1>")]
    [(client key mouse-key) (test-user:click-element! client (%entry-key client key) mouse-key)]))
