(import (tuna) (test) (test-user) (layout) (views) (buffers) (document) (keys) (commands) (hooks) (options) (tables) (modes)
        (layout-split) (editing) (ui) (ui-test) (ui-test status))

(define view ui-test:view)
(define visible ui-test:visible)
(define status-datum ui-test/status:status-datum)
(define hunk ui-test/status:hunk)
(define file ui-test/status:file)

(tables:set! ui:section-initial-visibility 'untracked 'hide)

(define b
  (buffers:make "*status*"
    (status-datum
      (ui:section '((type . untracked)) "Untracked files (1)" (ui:section '((type . file) (value . "new.txt")) "new.txt"))
      (ui:section '((type . unstaged)) "Unstaged changes (2)"
        (file "a.py" (hunk "@@ -1,3 +1,3 @@" " one" "-two" "+TWO" " three") (hunk "@@ -9,2 +9,2 @@" "-nine" "+NINE"))
        (file "b.txt" (hunk "@@ -1 +1 @@" "-beta" "+BETA")))
      (ui:section '((type . staged)) "Staged changes (1)" (file "b.txt" (hunk "@@ -1 +1 @@" "-alpha" "+ALPHA")))
      (ui:section '((type . stashes)) "Stashes (1)" "stash@{0} WIP"))))

(buffers:set-silent! b #t)
(modes:set-major-mode ui:section-mode b)
(ui-test:show! b)

(define v (view))

(define moved '())

(hooks:add! ui:section-moved (lambda (view section) (set! moved (cons (and section (ui:section-value section)) moved))))

(define (at-point) (let ([s (ui:section-at v)]) (and s (list (ui:section-type s) (ui:section-value s)))))

(define (n! keys) (test-user:press! keys) (at-point))

(define (each f items)
  (let loop ([items items] [acc '()])
    (if (null? items) (reverse acc) (loop (cdr items) (cons (f (car items)) acc)))))

(define (n-reporting! keys) (let ([m (ui-test:report-messages (lambda () (test-user:press! keys)))]) (list m (at-point))))

(define (find-section . identity) (ui:find-section b identity))

(test "a new view gives each section the visibility its type's entry or attribute says; stashes start hidden, as in Magit"
  (test-user:settle)
  (check-equal? '("Head:     main Second commit" "Untracked files (1)…" "Unstaged changes (2)" "modified   a.py" "@@ -1,3 +1,3 @@" " one" "-two"
                  "+TWO" " three" "@@ -9,2 +9,2 @@" "-nine" "+NINE" "modified   b.txt" "@@ -1 +1 @@" "-beta" "+BETA" "Staged changes (1)"
                  "modified   b.txt" "@@ -1 +1 @@" "-alpha" "+ALPHA" "Stashes (1)…")
                (visible v)))

(test "n moves to the first child of a shown section, else the next sibling, else the parent's next; p back; ^ to the parent; M-n and M-p by sibling"
  (check-equal? '((untracked #f) (unstaged #f) (file "a.py") (hunk "@@ -1,3 +1,3 @@") (hunk "@@ -9,2 +9,2 @@") (hunk "@@ -1,3 +1,3 @@")
                  (file "a.py") (unstaged #f) (staged #f) (unstaged #f))
    (each n! '("n" "n" "n" "n" "n" "p" "^" "^" "M-n" "M-p")))
  (check-equal? '(#f #f "a.py" "@@ -1,3 +1,3 @@" "@@ -9,2 +9,2 @@" "@@ -1,3 +1,3 @@" "a.py" #f #f #f) (reverse moved)))

(test "M-n and M-p with no sibling that way move as n and p"
  (check-equal? '((hunk "@@ -9,2 +9,2 @@") (file "b.txt") (hunk "@@ -1,3 +1,3 @@") (file "a.py"))
    (each n! '("M-< n n n n n" "M-n" "M-< n n n n" "M-p"))))

(test "n inside a hunk's lines goes to the next hunk, then the next file; p goes to the section's start, then the previous visible section"
  (views:set-point! v (+ (ui:section-heading-start (find-section '(hunk . "@@ -1,3 +1,3 @@") '(file . "a.py") '(unstaged . #f))) 18))
  (check-equal? '(hunk "@@ -1,3 +1,3 @@") (at-point))
  (check-equal? '((hunk "@@ -9,2 +9,2 @@") (file "b.txt") (hunk "@@ -9,2 +9,2 @@") (hunk "@@ -1,3 +1,3 @@") (file "a.py"))
    (each n! '("n" "n" "p" "p" "p"))))

(test "a count moves that many times and stops with the error at the end, and n at the last section stays there"
  (check-equal? '(file "b.txt") (n! "C-u 3 n"))
  (check-equal? '(("No next section") (stashes #f)) (n-reporting! "M-< C-u 2 0 n"))
  (let ([p (views:point v)])
    (check-equal? '(("No next section") (stashes #f)) (n-reporting! "n"))
    (check-equal? p (views:point v))))

(test "p at the first section and ^ at a top-level one stop at the buffer's first line, with the errors"
  (check-equal? '(("No previous section") #f) (n-reporting! "M-< p"))
  (check-equal? #f (n! "M-< n n ^"))
  (let ([doc (buffers:document b)] [p (views:point v)]) (check-equal? '(1 0) (list (document:line doc p) (document:column doc p))))
  (check-equal? '(("No previous section") #f) (n-reporting! "p"))
  (check-equal? '(("No parent section") #f) (n-reporting! "M-< ^")))

(test "point passes a hidden body in one step"
  (check-equal? '(unstaged #f) (n! "M-< n n"))
  (ui:hide-section! v (ui:section-at v))
  (check-equal? '(staged #f) (n! "C-e C-f"))
  (ui:show-section! v (find-section '(unstaged . #f))))

(test "TAB hides the section at point, its heading ending in an ellipsis, and shows it again with its children as they were"
  (check-equal? '(unstaged #f) (n! "M-< n n"))
  (test-user:press! "TAB")
  (check-equal? '("Head:     main Second commit" "Untracked files (1)…" "Unstaged changes (2)…" "Staged changes (1)" "modified   b.txt"
                  "@@ -1 +1 @@" "-alpha" "+ALPHA" "Stashes (1)…")
                (visible v))
  (test-user:press! "TAB")
  (check-equal? '(file "a.py") (n! "n TAB"))
  (let ([with-a-hidden '("Head:     main Second commit" "Untracked files (1)…" "Unstaged changes (2)" "modified   a.py…" "modified   b.txt"
                         "@@ -1 +1 @@" "-beta" "+BETA" "Staged changes (1)" "modified   b.txt" "@@ -1 +1 @@" "-alpha" "+ALPHA" "Stashes (1)…")])
    (check-equal? with-a-hidden (visible v))
    (check-equal? '(unstaged #f) (n! "^ TAB TAB"))
    (check-equal? with-a-hidden (visible v))))

(test "inside a body TAB hides the innermost section and moves point to its heading"
  (check-equal? '(hunk "@@ -9,2 +9,2 @@") (n! "n TAB n n C-n C-n"))
  (test-user:press! "TAB")
  (check-equal? (list '(hunk "@@ -9,2 +9,2 @@") #t) (list (at-point) (= (views:point v) (ui:section-heading-start (ui:section-at v)))))
  (check (member "@@ -9,2 +9,2 @@…" (visible v)))
  (test-user:press! "TAB")
  (check-equal? '(("Cannot hide root section") #f) (n-reporting! "M-< TAB")))

(define (cycle!) (test-user:press! "C-TAB") (visible v))

(test "C-TAB cycles a section: hidden; shown with its children hidden; everything; and is also C-c TAB and M-TAB"
  (check-equal? '(unstaged #f) (n! "M-< n n"))
  (let ([hidden '("Head:     main Second commit" "Untracked files (1)…" "Unstaged changes (2)…" "Staged changes (1)" "modified   b.txt"
                  "@@ -1 +1 @@" "-alpha" "+ALPHA" "Stashes (1)…")]
        [children '("Head:     main Second commit" "Untracked files (1)…" "Unstaged changes (2)" "modified   a.py…" "modified   b.txt…"
                    "Staged changes (1)" "modified   b.txt" "@@ -1 +1 @@" "-alpha" "+ALPHA" "Stashes (1)…")]
        [all '("Head:     main Second commit" "Untracked files (1)…" "Unstaged changes (2)" "modified   a.py" "@@ -1,3 +1,3 @@" " one" "-two"
               "+TWO" " three" "@@ -9,2 +9,2 @@" "-nine" "+NINE" "modified   b.txt" "@@ -1 +1 @@" "-beta" "+BETA" "Staged changes (1)"
               "modified   b.txt" "@@ -1 +1 @@" "-alpha" "+ALPHA" "Stashes (1)…")])
    (check-equal? (list hidden children all hidden children) (each (lambda (i) (cycle!)) (iota 5))))
  (check-equal? (list ui:section-cycle ui:section-cycle ui:section-cycle)
    (map (lambda (keys) (views:with-view v (keys:lookup (test-user:client) keys))) '("C-TAB" "C-c TAB" "M-TAB"))))

(test "S-TAB cycles every top-level section"
  (let ([shown '("Head:     main Second commit" "Untracked files (1)" "new.txt" "Unstaged changes (2)" "modified   a.py" "@@ -1,3 +1,3 @@"
                 " one" "-two" "+TWO" " three" "@@ -9,2 +9,2 @@" "-nine" "+NINE" "modified   b.txt" "@@ -1 +1 @@" "-beta" "+BETA"
                 "Staged changes (1)" "modified   b.txt" "@@ -1 +1 @@" "-alpha" "+ALPHA" "Stashes (1)" "stash@{0} WIP")]
        [hidden '("Head:     main Second commit" "Untracked files (1)…" "Unstaged changes (2)…" "Staged changes (1)…" "Stashes (1)…")])
    (check-equal? (list shown hidden shown) (each (lambda (i) (test-user:press! "S-TAB") (visible v)) (iota 3)))))

(test "1 to 4 show the sections around point to that level; M-1 to M-4 every section"
  (check-equal? '(file "a.py") (n! "M-< n n n n"))
  (test-user:press! "1")
  (check-equal? '((unstaged #f) ("Head:     main Second commit" "Untracked files (1)" "new.txt" "Unstaged changes (2)…" "Staged changes (1)"
                                  "modified   b.txt" "@@ -1 +1 @@" "-alpha" "+ALPHA" "Stashes (1)" "stash@{0} WIP"))
                (list (at-point) (visible v)))
  (check-equal? '(file "b.txt") (n! "n n 2"))
  (check-equal? '("Head:     main Second commit" "Untracked files (1)" "new.txt" "Unstaged changes (2)…" "Staged changes (1)"
                  "modified   b.txt…" "Stashes (1)" "stash@{0} WIP")
                (visible v))
  (test-user:press! "4")
  (check-equal? '("Head:     main Second commit" "Untracked files (1)" "new.txt" "Unstaged changes (2)…" "Staged changes (1)"
                  "modified   b.txt" "@@ -1 +1 @@" "-alpha" "+ALPHA" "Stashes (1)" "stash@{0} WIP")
                (visible v))
  (test-user:press! "M-1")
  (check-equal? '((staged #f) ("Head:     main Second commit" "Untracked files (1)…" "Unstaged changes (2)…" "Staged changes (1)…" "Stashes (1)…"))
                (list (at-point) (visible v)))
  (test-user:press! "M-3")
  (check-equal? '("Head:     main Second commit" "Untracked files (1)" "new.txt" "Unstaged changes (2)" "modified   a.py" "@@ -1,3 +1,3 @@…"
                  "@@ -9,2 +9,2 @@…" "modified   b.txt" "@@ -1 +1 @@…" "Staged changes (1)" "modified   b.txt" "@@ -1 +1 @@…"
                  "Stashes (1)" "stash@{0} WIP")
                (visible v))
  (test-user:press! "M-4"))

(define w (views:make b))

(test "each view shows and hides sections on its own"
  (views:set-point! w (ui:section-heading-start (find-section '(unstaged . #f))))
  (views:with-view w (ui:section-toggle))
  (check-equal? '(#t #f) (map (lambda (x) (ui:section-hidden? x (find-section '(unstaged . #f)))) (list w v))))

(define (current-datum)
  (status-datum
    (ui:section '((type . unstaged)) "Unstaged changes (3)"
      (file "a.py" (hunk "@@ -1,3 +1,3 @@" " one" "-two" "+TWO" " three"))
      (file "big.bin" (hunk "@@ -1 +1 @@" "-x" "+y"))
      (file "b.txt" (hunk "@@ -1 +1 @@" "-beta" "+BETA")))
    (ui:section '((type . staged) (hidden . #t)) "Staged changes (1)" (file "b.txt" (hunk "@@ -1 +1 @@" "-alpha" "+ALPHA")))
    (ui:section '((type . stashes)) "Stashes (1)" "stash@{0} WIP")
    (ui:section '((type . recent) (hidden . #t)) "Recent commits" "1a2b3c4 First commit")))

(test "rebuilding with reconcile! keeps each section's visibility; a new one starts as a chooser, its attribute or its type says"
  (ui:hide-section! v (find-section '(file . "a.py") '(unstaged . #f)))
  (ui:show-section! v (find-section '(stashes . #f)))
  (hooks:add! ui:section-visibility-choosers
    (lambda (view section) (and (eq? (ui:section-type section) 'file) (equal? (ui:section-value section) "big.bin") 'hide)))
  (buffers:reconcile! b (document:token (buffers:document b) 0) (cddr (current-datum)))
  (check-equal? '("Head:     main Second commit" "Unstaged changes (3)" "modified   a.py…" "modified   big.bin…" "modified   b.txt" "@@ -1 +1 @@"
                  "-beta" "+BETA" "Staged changes (1)" "modified   b.txt" "@@ -1 +1 @@" "-alpha" "+ALPHA" "Stashes (1)" "stash@{0} WIP"
                  "Recent commits…")
                (visible v))
  (check-equal? '("Head:     main Second commit" "Unstaged changes (3)…" "Staged changes (1)" "modified   b.txt" "@@ -1 +1 @@" "-alpha" "+ALPHA"
                  "Stashes (1)…" "Recent commits…")
                (visible w)))

(test "the section API: identity, parent, children, find, and argument checks"
  (let ([a-hunk (find-section '(hunk . "@@ -1,3 +1,3 @@") '(file . "a.py") '(unstaged . #f))])
    (check-equal? '((hunk . "@@ -1,3 +1,3 @@") (file . "a.py") (unstaged . #f)) (ui:section-identity a-hunk b))
    (check-equal? "a.py" (ui:section-value (ui:section-parent a-hunk b)))
    (check-equal? #f (ui:section-parent (ui:section-parent (ui:section-parent a-hunk b) b) b))
    (check-equal? '("a.py" "big.bin" "b.txt") (map ui:section-value (ui:section-children (find-section '(unstaged . #f)))))
    (check-equal? '() (ui:section-children a-hunk))
    (check-equal? #f (find-section '(nothing . #f))))
  (check-raises (ui-test:raised? 'ui:section "a section's type is not a symbol") (ui:section '((value . 1)) "No type"))
  (check-raises (ui-test:raised? 'ui:section-type "not a section") (ui:section-type 'x)))

(define (heading-of . identity) (ui:section-heading-start (apply find-section identity)))

(test "the region from one sibling's heading to another's selects them"
  (views:set-point! v (+ 2 (heading-of '(file . "a.py") '(unstaged . #f))))
  (views:set-mark! v (views:point v))
  (views:set-point! v (+ 3 (heading-of '(file . "b.txt") '(unstaged . #f))))
  (check-equal? '("a.py" "big.bin" "b.txt") (map ui:section-value (ui:section-selection v)))
  (views:set-point! v (+ 3 (heading-of '(file . "a.py") '(unstaged . #f))))
  (check-equal? #f (ui:section-selection v))
  (views:set-point! v (+ 3 (heading-of '(staged . #f))))
  (check-equal? #f (ui:section-selection v))
  (views:set-mark! v #f))

(define (section-classes) (map ui-test:classes (ui-test:elements v "ui-section")))

(test "a section is drawn as section.ui-section with its type, the one at point current, a hidden one hidden"
  (views:set-point! v (heading-of '(hunk . "@@ -1,3 +1,3 @@") '(file . "a.py") '(unstaged . #f)))
  (ui:show-section! v (find-section '(file . "a.py") '(unstaged . #f)))
  (check-equal? '(("ui-section") ("ui-section") ("ui-section" "current") ("ui-section" "hidden") ("ui-section") ("ui-section") ("ui-section")
                  ("ui-section") ("ui-section") ("ui-section") ("ui-section" "hidden"))
                (section-classes))
  (check-equal? '("unstaged" "file" "hunk") (map (lambda (e) (test-user:element-attribute e "data-type")) (list-head (ui-test:elements v "ui-section") 3)))
  (let ([chevron (car (ui-test:elements v "ui-section-chevron"))])
    (check-equal? '(span "true" "▾" clickable)
      (list (car chevron) (test-user:element-attribute chevron "aria-hidden") (test-user:element-text chevron) (ui-test:mark-state chevron))))
  (check (pair? (ui-test:elements v "ui-section-ellipsis")))
  (options:set! ui:highlight-current-section? #f)
  (check (for-all (lambda (cs) (not (member "current" cs))) (section-classes)))
  (options:unset! ui:highlight-current-section?))

(define (chevron-of . identity)
  (let ([at (number->string (apply heading-of identity))])
    (find (lambda (e) (pair? (filter (lambda (s) (equal? at (test-user:element-attribute s "data-at"))) (test-user:elements-with e "data-at"))))
          (ui-test:elements v "ui-section-heading"))))

(define (click-chevron! . identity)
  (let* ([p (apply heading-of identity)]
         [chevron (car (test-user:elements (apply chevron-of identity) "ui-section-chevron"))]
         [marks (cons "keymaps" (vector (ui-test:mark-number chevron)))])
    (ui-test:mouse! v "down" (list (cons "token" p)) marks)
    (ui-test:mouse! v "click" (list (cons "token" p)) marks)))

(test "a click on a chevron toggles its section and moves point to its heading; section-moved follows any command that changes the section at point"
  (set! moved '())
  (click-chevron! '(file . "b.txt") '(unstaged . #f))
  (check-equal? '((file "b.txt") #t) (list (at-point) (ui:section-hidden? v (find-section '(file . "b.txt") '(unstaged . #f)))))
  (click-chevron! '(file . "b.txt") '(unstaged . #f))
  (check-equal? #f (ui:section-hidden? v (find-section '(file . "b.txt") '(unstaged . #f))))
  (test-user:press! "C-n C-n")
  (check-equal? '("b.txt" "@@ -1 +1 @@") (reverse moved)))

(test "a click on a line selects its view, moves point there, and runs section-moved"
  (test-user:press! "C-x 2")
  (let ([v2 (find (lambda (x) (not (eq? x v))) (views:showing b))] [p (+ 3 (heading-of '(hunk . "@@ -1 +1 @@") '(file . "b.txt") '(unstaged . #f)))])
    (check (eq? (view) v))
    (set! moved '())
    (ui-test:click-at! v2 p)
    (check-equal? (list #t #t '("@@ -1 +1 @@")) (list (eq? (view) v2) (= (views:point v2) p) (reverse moved)))))

(test "rebuilding with the same datums edits nothing"
  (let* ([edits 0] [count (lambda (buffer edit) (when (eq? buffer b) (set! edits (+ edits 1))))])
    (hooks:add! buffers:after-edit count)
    (buffers:reconcile! b (document:token (buffers:document b) 0) (cddr (current-datum)))
    (hooks:remove! buffers:after-edit count)
    (check-equal? 0 edits)
    (check-equal? (document:datums (document:from-datum (current-datum))) (ui-test:datums b))))

(define (renamed value)
  (status-datum (ui:section `((type . unstaged) (value . ,value) (key . k)) "Unstaged" (ui:section '((type . stashes)) "Stashes" "stash@{0} WIP"))))

(test "a change of a section's value gives every section inside a new identity, so each starts again as its type says"
  (let ([c (buffers:make "*renamed*" (renamed "one"))])
    (buffers:set-silent! c #t)
    (modes:set-major-mode ui:section-mode c)
    (ui-test:show! c)
    (let ([u (view)])
      (ui:show-section! u (ui:find-section c '((stashes . #f) (unstaged . "one"))))
      (check-equal? '("Head:     main Second commit" "Unstaged" "Stashes" "stash@{0} WIP") (visible u))
      (let* ([renames 0] [count (lambda (buffer edit) (when (eq? buffer c) (set! renames (+ renames 1))))])
        (hooks:add! buffers:after-edit count)
        (buffers:reconcile! c (document:token (buffers:document c) 0) (cddr (renamed "two")))
        (hooks:remove! buffers:after-edit count)
        (check-equal? '(1 ("Head:     main Second commit" "Unstaged" "Stashes…")) (list renames (visible u)))))))
