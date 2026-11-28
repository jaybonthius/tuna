(import (tuna) (test) (test-browser) (test-runner) (cdp page) (keys) (views) (buffers) (document) (layout) (layout-split)
        (editing) (markdown) (options) (terminal) (modus) (flash) (flash-test))

(define light (test-browser:open (page-options [width 1200] [height 700] [color-scheme (color-scheme light)])))
(define dark (test-browser:open (page-options [width 1200] [height 700] [color-scheme (color-scheme dark)])))

(define code "(define (fox x)\n  (for-each fob x))\n;; a fox line, in the region\n")

(define prose
  "# Fox heading\n\nProse with a **bold fox** and an *italic fox*.\n\n| Name | Value |\n|------|-------|\n| fox | fob |\n\n---\n\nAfter the rule, a last fox.\n")

(define left (layout:selected-view))
(define code-buffer (buffers:make "*code*" code))
(views:set-buffer! left code-buffer)
(views:set-mark! left (document:line-start (buffers:document code-buffer) 3))
(views:set-point! left (- (document:line-start (buffers:document code-buffer) 4) 1))
(define before-split (layout:views))
(test-browser:press! light "C-x 3")
(define right (find (lambda (v) (not (memq v before-split))) (layout:views)))
(define prose-buffer
  (buffers:make "*prose*"
    (apply flash-test:page '() (append (markdown:blocks prose) (list (flash-test:word '((text . "foxtrot"))))))))
(views:set-buffer! right prose-buffer)
(layout:select! left)
(test-browser:wait-for-applied light)
(test-browser:wait-for-applied dark)

(define-record-type shot (fields nodes children))

(define (shot-of page)
  (let* ([nodes (test-browser:call (lambda () (page-snapshot page '("opacity" "position" "background-color"))))]
         [children (make-vector (vector-length nodes) '())])
    (let loop ([i (- (vector-length nodes) 1)])
      (when (>= i 0)
        (let ([p (snapshot-node-parent (vector-ref nodes i))])
          (when p (vector-set! children p (cons i (vector-ref children p)))))
        (loop (- i 1))))
    (make-shot nodes children)))

(define (node s i) (vector-ref (shot-nodes s) i))

(define (attribute s i name) (let ([a (assoc name (snapshot-node-attributes (node s i)))]) (and a (cdr a))))

(define (style s i name) (let ([a (assoc name (snapshot-node-styles (node s i)))]) (and a (cdr a))))

(define (where s keep?) (filter keep? (iota (vector-length (shot-nodes s)))))

(define (classes s i)
  (let ([c (attribute s i "class")])
    (if c
        (let loop ([chars (string->list c)] [word '()] [acc '()])
          (let ([add (lambda () (if (null? word) acc (cons (list->string (reverse word)) acc)))])
            (cond
              [(null? chars) (reverse (add))]
              [(char=? (car chars) #\space) (loop (cdr chars) '() (add))]
              [else (loop (cdr chars) (cons (car chars) word) acc)])))
        '())))

(define (ancestry s i) (if i (cons i (ancestry s (snapshot-node-parent (node s i)))) '()))

(define (last-text s i)
  (let walk ([i i] [found #f])
    (if (string=? "#text" (snapshot-node-name (node s i)))
        (if (snapshot-node-bounds (node s i)) i found)
        (fold-left (lambda (found c) (walk c found)) found (vector-ref (shot-children s) i)))))

(define (in-views? s i)
  (let ([ids (map (lambda (v) (number->string (views:id v))) (list left right))])
    (exists (lambda (a) (member (attribute s a "data-view") ids)) (ancestry s i))))

(define (geometry s)
  (let ([box (lambda (i) (let ([b (snapshot-node-bounds (node s i))])
                           (list (rectangle-x b) (rectangle-y b) (rectangle-width b) (rectangle-height b))))])
    (map (lambda (i)
           (let ([t (and (member "line" (classes s i)) (last-text s i))])
             (list (attribute s i "id") (box i)
                   (and t (let ([b (snapshot-node-bounds (node s t))]) (+ (rectangle-x b) (rectangle-width b)))))))
         (where s (lambda (i) (and (attribute s i "id") (snapshot-node-bounds (node s i)) (in-views? s i)
                                   (let ([c (classes s i)]) (or (member "line" c) (member "node" c)))))))))

(define (moved before after)
  (filter (lambda (b)
            (let ([a (assoc (car b) after)])
              (not (and a (for-all (lambda (x y) (< (abs (- x y)) 0.5)) (cadr b) (cadr a))
                        (or (not (caddr b)) (and (caddr a) (< (abs (- (caddr b) (caddr a))) 0.5)))))))
          before))

(define (opacity s i) (string->number (or (style s i "opacity") "1")))

;; A label on an atom standing alone is drawn on the first element its
;; kind drew.
(define (label-element s i)
  (if (member "node" (classes s i)) (car (vector-ref (shot-children s) i)) i))

(define (label-drawn? s i)
  (exists (lambda (c) (and (string=? "::before" (snapshot-node-name (node s c))) (equal? "absolute" (style s c "position"))))
          (vector-ref (shot-children s) (label-element s i))))

(define (full-opacity? s i)
  (= 1 (apply * (map (lambda (a) (opacity s a)) (ancestry s (label-element s i))))))

(define (labels-in s view)
  (let ([id (number->string (views:id view))])
    (where s (lambda (i) (and (attribute s i "data-flash-label")
                              (exists (lambda (a) (equal? id (attribute s a "data-view"))) (ancestry s i)))))))

;; A jump that asks the page what it shows draws its labels a screen
;; after the key's.
(define (shot-when page holds?)
  (test-runner:wait-until (lambda () (holds? (shot-of page))))
  (shot-of page))

(test "a jump moves no text, draws every label at full opacity over the text, dims the rest and keeps matches coloured in the region, light and dark"
  (for-each
    (lambda (page)
      (let ([before (geometry (shot-of page))])
        (test-browser:press! page "C-c ; f o")
        (let* ([s (shot-when page (lambda (s) (>= (length (where s (lambda (i) (attribute s i "data-flash-label")))) 9)))]
               [labels (where s (lambda (i) (attribute s i "data-flash-label")))])
          (check-equal? '() (moved before (geometry s)))
          (check-equal? '() (filter (lambda (i) (not (full-opacity? s i))) labels))
          (check-equal? '() (filter (lambda (i) (not (label-drawn? s i))) labels))
          (let ([dimmed (where s (lambda (i) (equal? "flash.backdrop" (attribute s i "data-face"))))])
            (check (pair? dimmed))
            (check-equal? '() (filter (lambda (i) (and (not (member "node" (classes s i))) (not (= 0.45 (opacity s i))))) dimmed))
            (check (exists (lambda (i) (and (member "node" (classes s i))
                                            (for-all (lambda (c) (= 0.45 (opacity s c))) (vector-ref (shot-children s) i))))
                           dimmed)))
          (let ([kept (where s (lambda (i) (and (equal? "match.other" (attribute s i "data-face")) (member "above-region" (classes s i)))))])
            (check (pair? kept))
            (check-equal? '() (filter (lambda (i) (equal? "rgba(0, 0, 0, 0)" (style s i "background-color"))) kept))))
        (check (for-all cancelled? (test-runner:reports-during (lambda () (test-browser:press! page "C-g")))))
        (test-browser:wait-for-applied page)
        (let ([s (shot-of page)])
          (check-equal? '() (moved before (geometry s)))
          (check-equal? '() (where s (lambda (i) (attribute s i "data-flash-label")))))))
    (list light dark)))

(test "a label on an atom standing alone is drawn over the atom's first element, at full opacity"
  (for-each
    (lambda (page)
      (test-browser:press! page "C-c ; f o")
      (let* ([s (shot-when page (lambda (s) (pair? (labels-in s right))))]
             [atoms (filter (lambda (i) (member "node" (classes s i))) (labels-in s right))])
        (check-equal? 1 (length atoms))
        (check (label-drawn? s (car atoms)))
        (check (full-opacity? s (car atoms))))
      (check (for-all cancelled? (test-runner:reports-during (lambda () (test-browser:press! page "C-g"))))))
    (list light dark)))

(test "a label in a terminal's faint cell is at full opacity, and output during a jump is searched at the next character"
  (options:set! terminal:shell '("bash" "--norc" "--noprofile"))
  (options:set! terminal:environment '(("PS1" . "$ ") ("HISTFILE" . #f)))
  (let ([t (terminal:start #f)])
    (views:set-buffer! right t)
    (terminal:send! t "clear; printf '\\e[2mfaint fox\\e[0m\\n'\r")
    (test-runner:wait-until (lambda () (test-browser:call (lambda () (pair? (page-query light "[data-ansi-colors~=\"faint\"]"))))))
    (test-browser:press! light "C-c ; f o")
    (let* ([s (shot-when light (lambda (s) (pair? (labels-in s right))))] [labels (labels-in s right)])
      (check-equal? 1 (length labels))
      (check (for-all (lambda (i) (full-opacity? s i)) labels))
      (check (exists (lambda (i) (exists (lambda (a) (equal? "faint" (attribute s a "data-ansi-colors"))) (ancestry s i)))
                     (where s (lambda (i) (equal? "match.other" (attribute s i "data-face")))))))
    (terminal:send! t "printf 'more fox\\n'\r")
    (test-runner:wait-until (lambda () (test-browser:call (lambda () (exists (lambda (e) (equal? "more fox" (element-text e))) (page-query light ".line"))))))
    (test-browser:press! light "x")
    ;; The shell echoes the command, so the output brings two matches.
    (check-equal? 3 (length (labels-in (shot-when light (lambda (s) (= 3 (length (labels-in s right))))) right)))
    (check (for-all cancelled? (test-runner:reports-during (lambda () (test-browser:press! light "C-g")))))))

(define tall-table
  (apply string-append "| Name | Value |\n|------|-------|\n"
    (map (lambda (i) (cond [(= i 3) "| fox one | x |\n"] [(= i 70) "| fox low | x |\n"] [else (format "| r~a | v~a |\n" i i)]))
         (iota 80))))

(define (box-of s i) (snapshot-node-bounds (node s i)))

;; A table taller than its view is drawn whole, and the view cuts it.
(test "a node drawn whole that the view cuts is searched only down to the row at the view's bottom"
  (views:set-buffer! right (buffers:make "*table*" (apply flash-test:page '() (markdown:blocks tall-table))))
  (test-browser:wait-for-applied light)
  (test-browser:press! light "C-c ; f o")
  (let* ([s (shot-when light (lambda (s) (pair? (labels-in s right))))]
         [view (find (lambda (i) (equal? (number->string (views:id right)) (attribute s i "data-view")))
                     (where s (lambda (i) (member "view" (classes s i)))))]
         [bottom (+ (rectangle-y (box-of s view)) (rectangle-height (box-of s view)))])
    (check-equal? 1 (length (labels-in s right)))
    (check (for-all (lambda (i) (< (rectangle-y (box-of s i)) bottom)) (labels-in s right))))
  (check (for-all cancelled? (test-runner:reports-during (lambda () (test-browser:press! light "C-g"))))))
