#!tuna
(import (buffers) (document) (views) (layout) (web) (test-user) (echo-area-test beneath))

(define (echo-buffer) (buffers:find " *Echo Area*"))

(define (echo-view) (car (views:showing (echo-buffer))))

(define (view) (layout:selected-view))

(define (messages) (document:text (buffers:document (buffers:find "*Messages*"))))

(define (log-lines)
  (let loop ([chars (string->list (messages))] [line '()] [acc '()])
    (cond
      [(null? chars) (reverse acc)]
      [(char=? (car chars) #\newline) (loop (cdr chars) '() (cons (list->string (reverse line)) acc))]
      [else (loop (cdr chars) (cons (car chars) line) acc)])))

(define (last-logged) (let ([lines (log-lines)]) (and (pair? lines) (car (last-pair lines)))))

(define element
  (case-lambda
    [() (element (test-user:client))]
    [(client)
     (let ([found (test-user:elements (test-user:screen client) "echo-area-message")])
       (and (pair? found) (car found)))]))

(define echo
  (case-lambda
    [() (echo (test-user:client))]
    [(client)
     (let ([e (element client)])
       (and e (let ([text (test-user:element-text e)]) (and (not (string=? text "")) text))))]))

(define (echo-element client)
  (let ([e (element client)])
    (and e (let ([found (test-user:elements e "echo-area-echo")]) (and (pair? found) (car found))))))

(define (prompt-parts client)
  (map test-user:element-text (test-user:elements (echo-element client) "echo-area-prompt")))

(define (faced client)
  (map (lambda (e) (list (test-user:element-attribute e "data-face") (test-user:element-text e)))
       (test-user:elements-with (echo-element client) "data-face")))

(define reports-during echo-area-test/beneath:reports-during)

(define (report-messages thunk)
  (map (lambda (c) (if (message-condition? c) (condition-message c) c)) (reports-during thunk)))

(define (raised? who message)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (message-condition? c) (string=? message (condition-message c)))))

(define (on-thread thunk)
  (let ([result #f])
    (join-task
      (fork-task
        (lambda (restore)
          (set! result
            (guard (c [(and (who-condition? c) (message-condition? c)) (list (condition-who c) (condition-message c))])
              (thunk))))))
    result))

(define (click-at! v at)
  (for-each
    (lambda (action)
      (web:post-input! (test-user:client)
        (list (cons "type" "mouse") (cons "action" action) (cons "button" 1) (cons "clicks" 1)
              (cons "modifiers" '#()) (cons "at" at) (cons "count" 0) (cons "view" (views:id v))
              (cons "version" (buffers:version (views:buffer v))) (cons "showing" (views:shown-count v)))))
    '("down" "click"))
  (test-user:settle))

(define (bottom-parts)
  (let ([root (car (document:datums (buffers:document layout:buffer)))])
    (map (lambda (d) (vector-ref d 1)) (cdddr (caddr root)))))

(define (layout-atoms)
  (let walk ([d (car (document:datums (buffers:document layout:buffer)))])
    (cond
      [(vector? d) (list (vector-ref d 1))]
      [(pair? d) (apply append (map walk (cddr d)))]
      [else '()])))
