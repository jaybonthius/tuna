#!tuna
(import (test-runner) (buffers) (document) (views) (layout) (web) (test-user))

(define (view) (layout:selected-view))

(define (show! b)
  (views:set-buffer! (view) b)
  (views:set-point! (view) 1))

;; Drawing the view as a page would be sent it, rather than reading the
;; layout's screen, lets a test read a view the layout does not show.
(define (drawn v)
  (let ([c (test-user:client)] [id (number->string (views:id v))])
    (web:send-screen! c (views:draw v c) "ui")
    (find (lambda (e) (equal? id (test-user:element-attribute e "data-view")))
          (test-user:elements (test-user:screen c) "view"))))

(define (elements v class) (test-user:elements (drawn v) class))

(define (classes element)
  (let ([value (test-user:element-attribute element "class")])
    (if value
        (let loop ([chars (string->list value)] [word '()] [words '()])
          (let ([add (lambda () (if (null? word) words (cons (list->string (reverse word)) words)))])
            (cond
              [(null? chars) (reverse (add))]
              [(char=? (car chars) #\space) (loop (cdr chars) '() (add))]
              [else (loop (cdr chars) (cons (car chars) word) words)])))
        '())))

(define (mark-state element)
  (let ([m (test-user:element-attribute element "data-keymap")])
    (and m (let ([space (let find ([k 0]) (cond [(= k (string-length m)) #f] [(char=? (string-ref m k) #\space) k] [else (find (+ k 1))]))])
             (and space (string->symbol (substring m (+ space 1) (string-length m))))))))

;; A user clicks what they see, so the view is drawn first.
(define click-at!
  (case-lambda
    [(v at) (click-at! v at "<mouse-1>")]
    [(v at key) (drawn v) (test-user:click! v at key)]))

(define (token-element at)
  (or (find (lambda (e) (equal? (number->string at) (test-user:element-attribute e "data-at")))
            (test-user:elements-with (test-user:screen) "data-to"))
      (assertion-violation 'ui-test:token-element "no element of the last screen stands for the token" at)))

;; A user clicks what an element shows, so the keymaps marked on the
;; elements inside it apply too.
(define (innermost element)
  (let ([inner (find (lambda (x) (and (pair? x) (symbol? (car x)) (not (eq? (car x) '\x40;)))) (cdr element))])
    (if inner (innermost inner) element)))

(define click-token!
  (case-lambda
    [(v at) (click-token! v at "<mouse-1>")]
    [(v at key) (drawn v) (test-user:click-element! (innermost (token-element at)) key)]))

(define (report-messages thunk)
  (map (lambda (c) (if (message-condition? c) (condition-message c) c)) (test-runner:reports-during thunk)))

(define (raised? who message)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (message-condition? c) (string=? message (condition-message c)))))

(define (text b) (document:text (buffers:document b)))

(define (datums b) (document:datums (buffers:document b)))

(define (all-folds v)
  (let ([doc (buffers:document (views:buffer v))])
    (let loop ([p 0] [acc '()])
      (if (= p (document:length doc))
          (reverse acc)
          (loop (+ p 1) (fold-left (lambda (acc f) (if (member f acc) acc (cons f acc))) acc (views:folds-at v p)))))))

(define (visible v)
  (let* ([doc (buffers:document (views:buffer v))] [n (document:length doc)] [folds (all-folds v)])
    (define (hidden? p) (exists (lambda (f) (and (< (car f) p) (<= p (cdr f)))) folds))
    (define (folded-here? p) (exists (lambda (f) (= (car f) p)) folds))
    (let loop ([p 0] [line '()] [start #f] [acc '()])
      (cond
        [(= p n) (reverse acc)]
        [(char? (document:token doc p))
         (let ([c (document:token doc p)])
           (if (char=? c #\newline)
               (loop (+ p 1) '() #f
                     (if (and start (not (hidden? start)))
                         (cons (string-append (list->string (reverse line)) (if (folded-here? p) "…" "")) acc)
                         acc))
               (loop (+ p 1) (cons c line) (or start p) acc)))]
        [else (loop (+ p 1) line start acc)]))))

(define %said '())

(define (say! x) (set! %said (cons x %said)))

(define (said) (reverse %said))
