(import (tuna) (test) (test-browser) (test-runner) (cdp page) (processes) (buffers) (views) (layout) (layout-split) (editing)
        (echo-area) (status-line) (minibuffer) (files) (ui) (git) (git-mode) (git-status) (git-test repositories))

(git-test/repositories:git! "" "init" "-q" "-b" "main" "repo")
(git-test/repositories:write-file! "repo/a.py" "one\ntwo\nthree\n")
(git-test/repositories:write-file! "repo/b.txt" "alpha\n")
(git-test/repositories:git! "repo" "add" "-A")
(git-test/repositories:git! "repo" "commit" "-qm" "First")
(git-test/repositories:write-file! "repo/a.py" "one\nTWO\nthree\n")
(git-test/repositories:write-file! "repo/b.txt" "ALPHA\n")
(git-test/repositories:git! "repo" "add" "b.txt")

(define repo (git:find-repository (git-test/repositories:path "repo")))

;; A plain git status may take the index lock to refresh it, and fail
;; the command a click runs at the same time.
(define (short)
  (let-values ([(status output errors)
                (processes:run "git" '("--no-optional-locks" "status" "--short") #f
                  (processes:options [directory (git:repository-root repo)]))])
    (utf8->string output)))

(define page (test-browser:open (page-options [width 1200] [height 900])))

(git-status:show repo)

(define (status-view) (find (lambda (v) (git-status:buffer? (views:buffer v))) (layout:views)))

(define (current!)
  (git-mode:wait-until-current (views:buffer (status-view)))
  (test-browser:wait-for-applied page))

(define (becomes! text)
  (test-runner:wait-until (lambda () (equal? text (short))))
  (current!))

(define (starts-with? s prefix)
  (and (>= (string-length s) (string-length prefix)) (string=? prefix (substring s 0 (string-length prefix)))))

(define (contains? s part)
  (let loop ([i 0])
    (and (<= (+ i (string-length part)) (string-length s))
         (or (string=? part (substring s i (+ i (string-length part)))) (loop (+ i 1))))))

(define (node-text nodes i)
  (let ([node (vector-ref nodes i)])
    (if (string=? "#text" (snapshot-node-name node))
        (snapshot-node-value node)
        (apply string-append
          (map (lambda (j) (node-text nodes j))
               (filter (lambda (j) (eqv? i (snapshot-node-parent (vector-ref nodes j)))) (iota (vector-length nodes))))))))

(define (has-class? node class)
  (let ([value (assoc "class" (snapshot-node-attributes node))])
    (and value (member class (let loop ([chars (string->list (cdr value))] [word '()] [words '()])
                               (cond
                                 [(null? chars) (reverse (if (null? word) words (cons (list->string (reverse word)) words)))]
                                 [(char=? #\space (car chars)) (loop (cdr chars) '() (if (null? word) words (cons (list->string (reverse word)) words)))]
                                 [else (loop (cdr chars) (cons (car chars) word) words)])))
         #t)))

(define (inside? nodes i j)
  (let ([parent (snapshot-node-parent (vector-ref nodes i))])
    (and parent (or (= parent j) (inside? nodes parent j)))))

;; chez-cdp finds elements by selector and rank, and a snapshot gives the
;; page's tree, so an element found in the snapshot is the one of its
;; rank among the selector's matches.
(define (classed nodes class)
  (filter (lambda (i) (has-class? (vector-ref nodes i) class)) (iota (vector-length nodes))))

(define (element nodes i class selector)
  (let ([rank (let loop ([matches (classed nodes class)] [k 0]) (if (= i (car matches)) k (loop (cdr matches) (+ k 1))))])
    (test-browser:call (lambda () (list-ref (page-query page selector) rank)))))

(define (snapshot) (test-browser:call (lambda () (page-snapshot page '("visibility")))))

(define (heading-node nodes text)
  (or (find (lambda (i) (contains? (node-text nodes i) text)) (classed nodes "ui-section-heading"))
      (errorf 'heading "no heading holds ~s" text)))

(define (heading text)
  (let ([nodes (snapshot)])
    (element nodes (heading-node nodes text) "ui-section-heading" ".ui-section-heading")))

(define (buttons-of nodes text label)
  (let ([h (heading-node nodes text)])
    (filter (lambda (i) (and (inside? nodes i h) (string=? label (node-text nodes i)))) (classed nodes "git-status-button"))))

(define (button text label)
  (let ([nodes (snapshot)])
    (element nodes (car (buttons-of nodes text label)) "git-status-button" ".git-status-button")))

(define (button-count text label) (length (buttons-of (snapshot) text label)))

(define (visibility element) (test-browser:call (lambda () (element-style element "visibility"))))

(define (hover! element) (test-browser:call (lambda () (element-hover! element))))

(define (click! element) (test-browser:call (lambda () (element-click! element))))

(current!)

(test "a row's buttons are hidden away from the pointer and shown under it"
  (hover! (car (test-browser:call (lambda () (page-query page ".status-line")))))
  (check-equal? "hidden" (visibility (button "modified   a.py" "+")))
  (hover! (heading "modified   a.py"))
  (check-equal? "visible" (visibility (button "modified   a.py" "+"))))

(test "a staged row has unstage and discard buttons, and a list's heading has buttons too"
  (check-equal? '(1 1 1) (list (button-count "modified   b.txt" "−") (button-count "modified   b.txt" "⟲") (button-count "Unstaged changes" "+"))))

(test "+ stages its row whatever point is, and point and the selected view stay; − unstages it"
  (let ([before (list (views:point (status-view)) (eq? (layout:selected-view) (status-view)))])
    (hover! (heading "modified   a.py"))
    (click! (button "modified   a.py" "+"))
    (becomes! "M  a.py\nM  b.txt\n")
    (check-equal? before (list (views:point (status-view)) (eq? (layout:selected-view) (status-view)))))
  (hover! (heading "modified   a.py"))
  (click! (button "modified   a.py" "−"))
  (becomes! " M a.py\nM  b.txt\n"))

(test "a hunk's heading carries the buttons, shown under the pointer"
  (ui:show-section! (status-view) (ui:find-section (views:buffer (status-view)) (list (cons 'file "a.py") (cons 'unstaged #f))))
  (current!)
  (hover! (heading "@@ -1,3 +1,3 @@"))
  (check-equal? "visible" (visibility (button "@@ -1,3 +1,3 @@" "+"))))

(test "a heading's text lines up with its body's and with a heading that has no body, the chevron left of them all"
  (let* ([nodes (snapshot)]
         [left (lambda (prefix)
                 (let ([line (find (lambda (i) (starts-with? (node-text nodes i) prefix)) (classed nodes "line"))])
                   (rectangle-x (snapshot-node-bounds (vector-ref nodes line)))))]
         [chevron (snapshot-node-bounds (vector-ref nodes (car (classed nodes "ui-section-chevron"))))])
    (check-equal? (list (left "Head:") (left "Head:")) (list (left "@@ -1,3") (left " one")))
    (check (<= (+ (rectangle-x chevron) (rectangle-width chevron)) (left " one")))))

(test "⟲ asks first, and y discards the row"
  (hover! (heading "modified   a.py"))
  (click! (button "modified   a.py" "⟲"))
  (let ([question (test-browser:call (lambda () (page-wait-for page ".minibuffer-question" (element-state visible))))])
    (check (contains? (test-browser:call (lambda () (element-text question))) "Discard unstaged changes")))
  (test-browser:press! page "y")
  (becomes! "M  b.txt\n")
  (check-equal? "one\ntwo\nthree\n" (call-with-input-file (git-test/repositories:path "repo/a.py") get-string-all)))
