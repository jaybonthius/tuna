#!tuna
(import (test-runner) (layout) (views) (buffers) (document) (search) (occur) (test-user) (isearch-test))

(define (view) (layout:selected-view))

(define (src! text)
  (let ([old (buffers:find "src")]) (when old (buffers:kill! old)))
  (let ([b (buffers:make "src" text)])
    (layout:switch-to-buffer b)
    (views:set-point! (view) 1)
    b))

(define (text-of b) (buffers:text-between (buffers:document b) 0 (document:length (buffers:document b))))

(define (occur-buffer) (buffers:find "*Occur*"))

(define (listed) (text-of (occur-buffer)))

(define (occur-view) (find (lambda (v) (eq? (views:buffer v) (occur-buffer))) (layout:views)))

(define (in-occur!) (layout:select! (occur-view)))

(define (wins)
  (map (lambda (v) (list (buffers:name (views:buffer v)) (views:point v) (eq? v (view))))
       (filter (lambda (v) (not (buffers:internal-name? (buffers:name (views:buffer v))))) (layout:views))))

(define (find-text b text)
  (let* ([doc (buffers:document b)] [n (document:length doc)] [k (string-length text)])
    (let loop ([p 0])
      (cond
        [(> (+ p k) n) #f]
        [(and (char? (document:token doc p)) (string=? (buffers:text-between doc p (+ p k)) text)) p]
        [else (loop (+ p 1))]))))

(define (where)
  (let* ([v (occur-view)] [doc (buffers:document (occur-buffer))] [p (views:point v)]
         [start (document:line-start doc (document:line doc p))])
    (buffers:text-between doc start p)))

(define %messages '())

(define (messages)
  (set! %messages (append %messages (isearch-test:take-said!)))
  %messages)

(define (last-message) (let ([m (messages)]) (and (pair? m) (car (last-pair m)))))

(define (clear-messages!) (messages) (set! %messages '()))

(define (%searched? text) (and (>= (string-length text) 9) (string=? "Searched " (substring text 0 9))))

;; A listing ends with its message, which an empty listing says too.
(define (listing! thunk)
  (clear-messages!)
  (thunk)
  (test-runner:wait-until (lambda () (exists %searched? (messages)))))

(define (occur! query context template)
  (listing! (lambda () (views:with-view (view) (occur:occur query context template)))))

(define (rx text) (search:make-query text search:regexp))

(define (occur-elements class)
  (test-user:settle)
  (let ([v (occur-view)])
    (if v (test-user:elements (isearch-test:view-element (test-user:client) v) class) '())))

(define (marked)
  (let ([arrow (find (lambda (e) (let ([t (test-user:element-text e)]) (and (>= (string-length t) 2) (string=? "=>" (substring t 0 2)))))
                     (occur-elements "occur-number"))])
    (and arrow
         (let ([t (test-user:element-text arrow)])
           (string->number (list->string (filter char-numeric? (string->list t))))))))

(define (pulsed v)
  (map cadr (filter (lambda (f) (string=? (car f) "pulse.highlight")) (isearch-test:faced (test-user:client) v))))

(define (source-view b) (find (lambda (v) (eq? (views:buffer v) b)) (layout:views)))

(define (only!)
  (let ([keep (view)])
    (let loop ()
      (let ([other (find (lambda (v) (and (not (eq? v keep)) (not (buffers:internal-name? (buffers:name (views:buffer v))))))
                         (layout:views))])
        (when other
          (layout:select! other)
          (test-user:press! "C-x 0")
          (loop))))
    (layout:select! keep)))

(define (reported keys)
  (map (lambda (c) (if (message-condition? c) (condition-message c) c))
       (test-runner:reports-during (lambda () (test-user:press! keys)))))
