#!tuna
(import (web) (views) (buffers) (layout) (test-user))

(define (%help-element)
  (let ([found (test-user:elements (test-user:screen) "help")])
    (and (pair? found) (car found))))

(define (%classes element)
  (let ([value (or (test-user:element-attribute element "class") "")])
    (let loop ([chars (string->list value)] [word '()] [words '()])
      (let ([add (lambda () (if (null? word) words (cons (list->string (reverse word)) words)))])
        (cond
          [(null? chars) (reverse (add))]
          [(char=? (car chars) #\space) (loop (cdr chars) '() (add))]
          [else (loop (cdr chars) (cons (car chars) word) words)])))))

(define (%children element)
  (let ([rest (cdr element)])
    (if (and (pair? rest) (pair? (car rest)) (eq? (caar rest) '\x40;)) (cdr rest) rest)))

(define (lines)
  (let ([help (%help-element)])
    (if (not help)
        '()
        (let ([found '()])
          (let walk ([node help] [prefix ""])
            (when (pair? node)
              (let ([classes (%classes node)])
                (cond
                  [(member "line" classes)
                   (set! found (cons (string-append prefix (%text node)) found))]
                  [else
                   (let ([prefix (cond
                                   [(member "help-title" classes) "# "]
                                   [(member "help-heading" classes) "## "]
                                   [else prefix])])
                     (for-each (lambda (child) (walk child prefix)) (%children node)))]))))
          (reverse found)))))

(define (%text node)
  (cond
    [(string? node) node]
    [(pair? node)
     (let ([inner (apply string-append (map %text (%children node)))] [classes (%classes node)])
       (cond
         [(member "help-key" classes) (string-append "[" inner "]")]
         [(member "ui-link" classes) (string-append "<" inner ">")]
         [else inner]))]
    [else ""]))

(define (title)
  (let ([ls (lines)])
    (and (pair? ls) (substring (car ls) 2 (string-length (car ls))))))

(define (outline) (filter (lambda (l) (and (fx> (string-length l) 0) (char=? (string-ref l 0) #\#))) (lines)))

(define (help-view)
  (let ([b (buffers:find "*Help*")])
    (and b (let ([vs (views:showing b)]) (and (pair? vs) (car vs))))))

;; A page sends a click as the place of the node drawn around what was
;; clicked.
(define (link-token name)
  (let ([nodes (filter (lambda (n)
                         (exists (lambda (l) (equal? name (test-user:element-text l)))
                                 (test-user:elements n "ui-link")))
                       (test-user:elements (%help-element) "node"))])
    (string->number (test-user:element-attribute (car (last-pair nodes)) "data-at"))))

(define (%mouse! view action button place)
  (web:post-input! (test-user:client)
    (append place
            (list (cons "type" "mouse") (cons "action" action) (cons "button" button) (cons "clicks" 1)
                  (cons "modifiers" (vector)) (cons "view" (views:id view)) (cons "showing" (views:shown-count view))
                  (cons "version" (buffers:version (views:buffer view))) (cons "report" 1))))
  (test-user:settle))

(define (click! view place)
  (%mouse! view "down" 1 place)
  (%mouse! view "click" 1 place))

(define (click-link! name) (click! (help-view) (list (cons "token" (link-token name)))))
