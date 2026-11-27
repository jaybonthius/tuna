#!tuna
(import (web) (keys) (layout) (views) (buffers) (document) (haml))

(define-record-type %page
  (sealed #t)
  (fields (mutable screen) (mutable title) (mutable calls) answer))

(define %pages (make-weak-eq-hashtable))

(define %answered? #f)

(define open-client
  (case-lambda
    [() (open-client (lambda (name value) 'null))]
    [(answer)
     (unless (procedure? answer)
       (assertion-violation 'test-user:open-client "not a procedure" answer))
     (let* ([page (make-%page #f #f '() answer)]
            [client (web:open-client
                      (lambda (client screen title)
                        (%page-screen-set! page screen)
                        (%page-title-set! page title))
                      (lambda (client name value) (%page-calls-set! page (cons (cons name value) (%page-calls page))))
                      (lambda (client name value)
                        (set! %answered? #t)
                        ((%page-answer page) name value)))])
       (hashtable-set! %pages client page)
       client)]))

(define %first (open-client))

(define (client) %first)

(define (%page-of who client)
  (or (hashtable-ref %pages client #f)
      (assertion-violation who "not a client test-user opened" client)))

;; A task spawned now runs after the tasks queued before it, and the
;; resume it queues while this task is paused runs only once their batch
;; has ended, so the screens are drawn by then. A page answers in that
;; draw, so a command that asked continues only in the next batch.
(define (settle)
  (set! %answered? #f)
  (suspend (lambda (resume) (spawn-task (lambda (restore) (resume void)))))
  (when %answered? (settle)))

;; Each key is posted once Tuna has handled the one before, as a user who
;; types after the screen changes does, so its quit mark is the one the
;; page would have from keys by then: none while a command reads a key.
(define (%press-key! client key)
  (web:post-input! client
    (if (member key (keys:page-quit-keys client))
        (list (cons "type" "key") (cons "name" key) (cons "quit" #t))
        (list (cons "type" "key") (cons "name" key))))
  (settle))

(define press!
  (case-lambda
    [(keys) (press! %first keys)]
    [(client keys)
     (%page-of 'test-user:press! client)
     (for-each (lambda (key) (%press-key! client key)) (keys:sequence-keys keys))]))

(define (%char-key c)
  (case c
    [(#\space) "SPC"]
    [(#\newline) "RET"]
    [(#\tab) "TAB"]
    [else (and (not (eq? (char-general-category c) 'Cc)) (string c))]))

(define type!
  (case-lambda
    [(text) (type! %first text)]
    [(client text)
     (%page-of 'test-user:type! client)
     (unless (string? text)
       (assertion-violation 'test-user:type! "not a string" text))
     (let ([keys (map %char-key (string->list text))])
       (unless (for-all values keys)
         (assertion-violation 'test-user:type! "a character that is no key" text))
       (for-each (lambda (key) (%press-key! client key)) keys))]))

(define (%check-point-mark who point-mark)
  (unless (char? point-mark)
    (assertion-violation who "not a character" point-mark)))

(define show!
  (case-lambda
    [(text) (show! text #\|)]
    [(text point-mark)
     (unless (string? text)
       (assertion-violation 'test-user:show! "not a string" text))
     (%check-point-mark 'test-user:show! point-mark)
     (let ([marks (filter (lambda (i) (char=? (string-ref text i) point-mark)) (iota (string-length text)))])
       (unless (= (length marks) 1)
         (assertion-violation 'test-user:show! "not one point mark in the text" text point-mark))
       (let* ([at (car marks)]
              [b (buffers:make (buffers:free-name "*test*")
                   (string-append (substring text 0 at) (substring text (fx+ at 1) (string-length text))))]
              [v (layout:selected-view)])
         (views:set-buffer! v b)
         (views:set-point! v (document:position (buffers:document b) at (document:unit characters)))))]))

(define text
  (case-lambda
    [() (text #\|)]
    [(point-mark)
     (%check-point-mark 'test-user:text point-mark)
     (let* ([v (layout:selected-view)] [doc (buffers:document (views:buffer v))] [at (views:point v)])
       (string-append (buffers:text-between doc 0 at) (string point-mark)
                      (buffers:text-between doc at (document:length doc))))]))

(define (%given who client accessor)
  (let ([page (%page-of who client)])
    (unless (%page-screen page)
      (assertion-violation who "no screen has been given to the client" client))
    (accessor page)))

(define screen
  (case-lambda
    [() (screen %first)]
    [(client) (html->sxml (%given 'test-user:screen client %page-screen))]))

(define title
  (case-lambda
    [() (title %first)]
    [(client) (%given 'test-user:title client %page-title)]))

(define (%element? v)
  (and (list? v) (pair? v) (symbol? (car v)) (not (eq? (car v) '\x40;))))

(define (%check-element who v)
  (unless (%element? v)
    (assertion-violation who "not an SXML element" v)))

(define (%attributes element)
  (let ([rest (cdr element)])
    (if (and (pair? rest) (pair? (car rest)) (eq? (caar rest) '\x40;)) (cdar rest) '())))

(define (%children element)
  (let ([rest (cdr element)])
    (if (and (pair? rest) (pair? (car rest)) (eq? (caar rest) '\x40;)) (cdr rest) rest)))

(define (%attribute element name)
  (let ([a (find (lambda (a) (string=? (symbol->string (car a)) name)) (%attributes element))])
    (and a (cadr a))))

(define (%class-names value)
  (let loop ([chars (string->list value)] [word '()] [words '()])
    (let ([add (lambda () (if (null? word) words (cons (list->string (reverse word)) words)))])
      (cond
        [(null? chars) (reverse (add))]
        [(char-whitespace? (car chars)) (loop (cdr chars) '() (add))]
        [else (loop (cdr chars) (cons (car chars) word) words)]))))

(define (elements sxml class)
  (%check-element 'test-user:elements sxml)
  (unless (string? class)
    (assertion-violation 'test-user:elements "not a string" class))
  (let walk ([node sxml])
    (if (%element? node)
        (let ([below (apply append (map walk (%children node)))] [value (%attribute node "class")])
          (if (and value (member class (%class-names value))) (cons node below) below))
        '())))

(define (element-text element)
  (%check-element 'test-user:element-text element)
  (call-with-string-output-port
    (lambda (p)
      (let walk ([node element])
        (cond
          [(string? node) (put-string p node)]
          [(%element? node) (for-each walk (%children node))])))))

(define (element-attribute element name)
  (%check-element 'test-user:element-attribute element)
  (unless (string? name)
    (assertion-violation 'test-user:element-attribute "not a string" name))
  (%attribute element name))

(define take-page-calls!
  (case-lambda
    [() (take-page-calls! %first)]
    [(client)
     (let* ([page (%page-of 'test-user:take-page-calls! client)] [calls (reverse (%page-calls page))])
       (%page-calls-set! page '())
       calls)]))
