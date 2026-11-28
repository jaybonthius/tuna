#!tuna
(import (test-user) (test-runner) (views) (buffers) (document) (layout) (keys) (echo-area) (haml) (flash))

;; A user's page reports what it shows of each view; this one shows the
;; whole of a view unless a test gives the range.
(define %ranges (make-weak-eq-hashtable))

(define (show-range! view start end) (eq-hashtable-set! %ranges view (cons start end)))

(define (show-all! view) (eq-hashtable-delete! %ranges view))

(define (%answer name value)
  (let ([v (and (equal? name "views-shown") (views:find (cdr (assoc "view" value))))])
    (if (and v (views:buffer v))
        (let ([range (or (eq-hashtable-ref %ranges v #f) (call-with-values (lambda () (views:bounds v)) cons))])
          (list (cons "version" (buffers:version (views:buffer v)))
                (cons "start" (list (cons "at" (car range))))
                (cons "end" (list (cons "at" (cdr range))))))
        'null)))

(define %user (test-user:open-client %answer))

(define (user) %user)

(define (open-user) (test-user:open-client %answer))

(define press!
  (case-lambda
    [(keys) (test-user:press! %user keys)]
    [(client keys) (test-user:press! client keys)]))

(define (view) (layout:selected-view))

;; Keys that quit a jump raise &cancelled in the command that started it,
;; which the command's report carries.
(define quitting!
  (case-lambda
    [(keys) (quitting! %user keys)]
    [(client keys)
     (let ([reports (test-runner:reports-during (lambda () (test-user:press! client keys)))])
       (and (pair? reports) (for-all cancelled? reports)))]))

(define show!
  (case-lambda
    [(text) (test-user:show! text) (test-user:settle)]
    [(text point-mark) (test-user:show! text point-mark) (test-user:settle)]))

(define (text) (test-user:text))

(define (position offset)
  (document:position (buffers:document (views:buffer (view))) offset (document:unit characters)))

(define prompt
  (case-lambda
    [() (keys:prompt %user)]
    [(client) (keys:prompt client)]))

(define (%view-element client v)
  (let ([id (number->string (views:id v))])
    (find (lambda (e) (equal? id (test-user:element-attribute e "data-view")))
          (test-user:elements-with (test-user:screen client) "data-view"))))

(define (%children e)
  (let ([rest (cdr e)])
    (if (and (pair? rest) (pair? (car rest)) (eq? (caar rest) '\x40;)) (cdr rest) rest)))

(define lines
  (case-lambda
    [() (lines %user (view))]
    [(v) (lines %user v)]
    [(client v)
     (let ([e (%view-element client v)])
       (if e
           (map (lambda (line)
                  (call-with-string-output-port
                    (lambda (p)
                      (let walk ([node line])
                        (cond
                          [(string? node) (put-string p node)]
                          [(pair? node)
                           (let ([label (test-user:element-attribute node "data-flash-label")])
                             (when label (put-string p (string-append "{" label "}")))
                             (for-each walk (%children node)))])))))
                (filter (lambda (l) (test-user:element-attribute l "data-line")) (test-user:elements e "line")))
           '()))]))

(define faced
  (case-lambda
    [() (faced %user (view))]
    [(client v)
     (let ([e (%view-element client v)])
       (if e
           (map (lambda (f) (list (test-user:element-attribute f "data-face") (test-user:element-text f)))
                (test-user:elements-with e "data-face"))
           '()))]))

(define with-attribute
  (case-lambda
    [(name) (with-attribute %user (view) name)]
    [(client v name)
     (let ([e (%view-element client v)])
       (if e (test-user:elements-with e name) '()))]))

(define (word-text node) (document:node-attribute node 'text ""))

(define (draw-word node view) (haml (:span (word-text node))))

(buffers:define-kind page (content nodes))
(buffers:define-kind para)
(buffers:define-kind quiet (stops none))
(buffers:define-kind word (content atom) (text word-text) (draw draw-word))

(define (show-buffer! b)
  (views:set-buffer! (view) b)
  (views:set-point! (view) 0)
  (test-user:settle))

(keys:bind! keys:global "C-c ;" flash:jump)
