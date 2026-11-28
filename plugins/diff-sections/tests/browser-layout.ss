(import (tuna) (test) (test-browser) (test-runner) (cdp page) (options) (buffers) (document) (views) (layout) (layout-split) (editing)
        (echo-area) (status-line) (minibuffer) (ui) (diff) (diff-sections) (diff-sections-test))

(define page (test-browser:open (page-options [width 1400] [height 900])))

(define files
  (diff-sections-test:parse
    "diff --git a/a.py b/a.py\nindex 1..2 100644\n--- a/a.py\n+++ b/a.py\n@@ -1,4 +1,4 @@\n one\n-two\n-three\n+TWO\n+THREE\n four\n"))

(define (show!)
  (diff-sections-test:show! (diff-sections:file-section (car files)))
  (test-browser:wait-for-applied page))

(define (attribute node name) (let ([a (assoc name (snapshot-node-attributes node))]) (and a (cdr a))))

(define (has-class? node class)
  (let ([value (attribute node "class")])
    (and value (let loop ([words (let split ([cs (string->list value)] [w '()] [acc '()])
                                   (cond
                                     [(null? cs) (reverse (if (null? w) acc (cons (list->string (reverse w)) acc)))]
                                     [(char=? (car cs) #\space) (split (cdr cs) '() (if (null? w) acc (cons (list->string (reverse w)) acc)))]
                                     [else (split (cdr cs) (cons (car cs) w) acc)]))])
                 (and (pair? words) (or (string=? (car words) class) (loop (cdr words))))))))

(define (lines)
  (let ([nodes (test-browser:call (lambda () (page-snapshot page '("visibility"))))])
    (map (lambda (node) (let ([r (snapshot-node-bounds node)]) (list (attribute node "data-side") (rectangle-x r) (rectangle-y r))))
         (filter (lambda (node) (and (has-class? node "diff-sections-line") (snapshot-node-bounds node))) (vector->list nodes)))))

(define (columns) (map (lambda (l) (list (car l) (cadr l))) (lines)))

(test "unified draws every line in one column, one under the other"
  (show!)
  (let ([ls (lines)])
    (check-equal? 6 (length ls))
    (check (apply = (map cadr ls)))
    (check (apply < (map caddr ls)))))

(test "split draws removed lines in the left column and added lines in the right, each pair on one row; the text is the patch"
  (options:set! diff-sections:layout (diff-sections:layout-mode split))
  (show!)
  (let* ([ls (lines)] [left (filter (lambda (l) (equal? "left" (car l))) ls)] [right (filter (lambda (l) (equal? "right" (car l))) ls)])
    (check-equal? '(2 2) (list (length left) (length right)))
    (check (for-all (lambda (l r) (and (< (cadr l) (cadr r)) (= (caddr l) (caddr r)))) left right)))
  (check-equal? "modified   a.py\n@@ -1,4 +1,4 @@\n one\n-two\n-three\n+TWO\n+THREE\n four\n"
                (diff-sections-test:text (views:buffer (diff-sections-test:view)))))

(test "automatic draws split in a wide view and unified in a narrow one"
  (options:set! diff-sections:layout (diff-sections:layout-mode automatic))
  (show!)
  (let ([ls (lines)])
    (check (not (apply = (map cadr ls)))))
  (test-browser:press! page "C-x 3")
  (test-browser:press! page "C-x 3")
  (test-browser:wait-for-applied page)
  (let ([narrow (filter (lambda (l) (< (cadr l) 300)) (lines))])
    (check (pair? narrow))
    (check (apply = (map cadr narrow))))
  (options:unset! diff-sections:layout))

(define (element selector rank) (test-browser:call (lambda () (list-ref (page-query page selector) rank))))

(define (box selector rank) (test-browser:call (lambda () (element-box (element selector rank)))))

(define (line-of-point)
  (let* ([b (views:buffer (diff-sections-test:view))] [doc (buffers:document b)] [p (views:point (diff-sections-test:view))])
    (let loop ([q (document:line-start doc (document:line doc p))] [acc '()])
      (let ([t (and (< q (document:length doc)) (document:token doc q))])
        (cond
          [(or (not t) (eqv? t #\newline)) (list->string (reverse acc))]
          [(char? t) (loop (+ q 1) (cons t acc))]
          [else (loop (+ q 1) acc)])))))

(test "in two columns the cursor is drawn on its line, in the right column for an added line"
  (options:set! diff-sections:layout (diff-sections:layout-mode split))
  (show!)
  (views:set-point! (diff-sections-test:view) (+ 1 (diff-sections-test:line-position (views:buffer (diff-sections-test:view)) "+TWO")))
  (test-browser:wait-for-applied page)
  (let ([cursor (box ".cursor.primary, .cursor-on.primary" 0)] [right (box ".diff-sections-line[data-side=\"right\"]" 0)])
    (check (<= (rectangle-x right) (rectangle-x cursor) (+ (rectangle-x right) (rectangle-width right))))
    (check (<= (rectangle-y right) (rectangle-y cursor) (+ (rectangle-y right) (rectangle-height right))))))

(test "a click on a line of the right column puts point on that line; a click on a context line's second copy, on its text"
  (test-browser:click! page (element ".diff-sections-line[data-side=\"right\"] .diff-sections-text" 1))
  (check-equal? "+THREE" (line-of-point))
  (test-browser:click! page (element ".diff-sections-copy" 1))
  (check-equal? " four" (line-of-point)))

(test "a line too long for its column wraps within it, and nothing scrolls sideways"
  (let ([long (diff-sections-test:parse
                (string-append "diff --git a/l.py b/l.py\nindex 1..2 100644\n--- a/l.py\n+++ b/l.py\n@@ -1 +1 @@\n-short\n+"
                               (make-string 300 #\x) "\n"))])
    (diff-sections-test:show! (diff-sections:file-section (car long)))
    (test-browser:wait-for-applied page)
    (let ([heading (box ".ui-section-heading" 1)] [right (box ".diff-sections-line[data-side=\"right\"]" 0)])
      (check (<= (+ (rectangle-x right) (rectangle-width right)) 1400))
      (check (> (rectangle-height right) (* 3 (rectangle-height heading))))))
  (options:unset! diff-sections:layout))

(test "an answer that rearranges the rows does not move the lines above it in the view"
  (options:set! diff-sections:layout (diff-sections:layout-mode split))
  (let* ([requests '()]
         [refiner (diff-sections:make-refiner "held" (lambda () #t) (lambda (request) (set! requests (cons request requests))))]
         [files (diff-sections-test:parse
                  "diff --git a/m.py b/m.py\nindex 1111aaa..2222bbb 100644\n--- a/m.py\n+++ b/m.py\n@@ -1,3 +1,3 @@\n top\n-a\n-b\n+B\n+A\n")]
         [b (diff-sections-test:show! (diff-sections:file-section (car files)))])
    (buffers:with-buffer b (options:set-local! diff-sections:refiner refiner diff-sections:source (lambda (container external fs) #vu8())))
    (diff-sections:refine! b)
    (test-browser:wait-for-applied page)
    (let ([before (box ".diff-sections-line" 0)])
      (diff-sections:deliver! (car requests)
        (list (diff-sections:make-refinement (string->utf8 "m.py") "1111aaa" "2222bbb" '() '((1 . 1) (2 . 3) (3 . 2)) #f)))
      (test-browser:wait-for-applied page)
      (let ([after (box ".diff-sections-line" 0)])
        (check-equal? (list (rectangle-x before) (rectangle-y before)) (list (rectangle-x after) (rectangle-y after))))
      (check-equal? '("left" "left" "right" "right")
                    (map (lambda (i) (test-browser:call (lambda () (element-attribute (element ".diff-sections-line" i) "data-side")))) '(1 2 3 4)))))
  (options:unset! diff-sections:layout))
