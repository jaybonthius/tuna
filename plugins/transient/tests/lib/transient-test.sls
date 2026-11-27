#!tuna
(import (web) (views) (buffers) (layout) (test-user))

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

;; A page sends a click as the place of the innermost node drawn around
;; what was clicked.
(define (entry-token key)
  (let ([nodes (filter (lambda (n)
                         (exists (lambda (k) (equal? key (test-user:element-text k))) (test-user:elements n "transient-key")))
                       (test-user:elements (test-user:screen) "node"))])
    (string->number (test-user:element-attribute (car (last-pair nodes)) "data-at"))))

(define (%mouse! client view action button place)
  (web:post-input! client
    (append place
            (list (cons "type" "mouse") (cons "action" action) (cons "button" button) (cons "clicks" 1)
                  (cons "modifiers" (vector)) (cons "view" (views:id view)) (cons "showing" (views:shown-count view))
                  (cons "version" (buffers:version (views:buffer view))) (cons "report" 1))))
  (test-user:settle))

(define (click! client view button place)
  (%mouse! client view "down" button place)
  (%mouse! client view "click" button place))

(define click-entry!
  (case-lambda
    [(key) (click-entry! (test-user:client) key 1)]
    [(client key button) (click! client (popup-view) button (list (cons "token" (entry-token key))))]))
