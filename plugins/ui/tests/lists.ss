(import (tuna) (test) (test-user) (web) (layout) (views) (buffers) (document) (keys) (commands) (editing) (ui) (ui-test))

(define view ui-test:view)

(define b (buffers:make "*rows*" (ui:list '())))
(define (lst) (document:token (buffers:document b) 0))
(define chosen '())
(define (choose i) (set! chosen (cons i chosen)))
(define (number-row i) (ui:label (number->string i)))
(define (generations) (map (lambda (a) (cdr (assq 'generation (vector-ref a 1)))) (cddr (car (ui-test:datums b)))))
(define (selected) (ui:selected-row (lst) (view)))

(define (rows-drawn v)
  (map (lambda (e) (list (test-user:element-text e) (test-user:element-attribute e "aria-current") (ui-test:mark-state e)))
       (ui-test:elements v "ui-list-row")))

(ui-test:show! b)

(test "a list holds one atom per row, all of one datum for one set-rows!, drawn as li.ui-list-row in a ul.ui-list, the selected row aria-current"
  (ui:set-rows! b (lst) 5 number-row choose)
  (check-equal? '(0 0 0 0 0) (generations))
  (check-equal? '(("0" "true" clickable) ("1" #f clickable) ("2" #f clickable) ("3" #f clickable) ("4" #f clickable)) (rows-drawn (view)))
  (let ([ul (car (ui-test:elements (view) "ui-list"))])
    (check-equal? '(ul inert) (list (car ul) (ui-test:mark-state ul)))))

(test "point rests before the selected row's atom, which describe-list numbers among all the rows"
  (ui:set-rows! b (lst) 100 number-row choose)
  (check-equal? "row 1 of 100" (ui:describe-list (lst) (view)))
  (check-equal? "row 1 of 100" (views:with-view (view) (views:describe-at-point (view)))))

(test "moving through the rows only moves point; the rows stay"
  (let ([v0 (buffers:version b)])
    (test-user:press! "C-n <down> C-n")
    (check-equal? (list 3 4 0) (list (selected) (views:point (view)) (- (buffers:version b) v0)))
    (test-user:press! "C-u 3 C-p <up>")
    (check-equal? 0 (selected))
    (views:with-view (view) (commands:run ui:next-row 500))
    (check-equal? (list 99 0) (list (selected) (- (buffers:version b) v0)))))

(test "only the rows a view draws are drawn: before its page reports, 100 each side of point"
  (let ([drawn-rows (make-eqv-hashtable)])
    (ui:set-rows! b (lst) 1000 (lambda (i) (hashtable-set! drawn-rows i #t) (number-row i)) choose)
    (ui:select-row! (lst) (view) 500)
    (hashtable-clear! drawn-rows)
    (ui-test:drawn (view))
    (let ([rows (vector->list (hashtable-keys drawn-rows))])
      (check-equal? '(201 400 600) (list (length rows) (apply min rows) (apply max rows))))))

(test "a million rows are one edit, and new rows keep each view's index clamped"
  (ui:set-rows! b (lst) 1000000 number-row choose)
  (ui:select-row! (lst) (view) 999999)
  (check-equal? "row 1000000 of 1000000" (ui:describe-list (lst) (view)))
  (ui:set-rows! b (lst) 100 number-row choose)
  (check-equal? 99 (selected)))

(test "select-row! shows the row it selects, even the one already selected"
  (ui:select-row! (lst) (view) 99)
  (check (views:following? (view))))

(test "RET, or a click or middle click on a row, calls choose with the row, the click first moving point to it"
  (test-user:press! "RET")
  (ui-test:click-token! (view) 97)
  (check-equal? '((96 99) 96) (list chosen (selected)))
  (ui-test:click-token! (view) 98 '("button" . 2))
  (check-equal? '((97 96 99) 97) (list chosen (selected)))
  (set! chosen (cdr chosen))
  (ui:select-row! (lst) (view) 96))

(test "two views of one buffer select independently, each drawing its own row as the selected one"
  (let ([other (views:make b)])
    (ui:select-row! (lst) other 98)
    (check-equal? '(96 98) (list (selected) (ui:selected-row (lst) other)))
    (check-equal? '("96" "98")
      (map (lambda (v) (test-user:element-text (find (lambda (e) (test-user:element-attribute e "aria-current")) (ui-test:elements v "ui-list-row"))))
           (list (view) other)))
    (let ([letters (lambda (v) (lambda (i) (ui:label (symbol->string (vector-ref v i)))))])
      (ui:set-rows! b (lst) 3 (letters (vector 'a 'b 'c)) choose)
      (check-equal? '(2 2 (5 5 5)) (list (selected) (ui:selected-row (lst) other) (generations)))
      (ui:select-row! (lst) (view) 0)
      (ui:set-rows! b (lst) 4 (letters (vector 'x 'y 'z 'w)) choose)
      (check-equal? '(0 2 (6 6 6 6)) (list (selected) (ui:selected-row (lst) other) (generations))))
    (ui:set-rows! b (lst) 4 number-row choose)
    (let ([v1 (buffers:version b)])
      (ui:add-rows! b (lst) 2)
      (check-equal? (list 0 2 '(7 7 7 7 7 7) 1) (list (selected) (ui:selected-row (lst) other) (generations) (- (buffers:version b) v1))))
    (ui-test:click-token! (view) 6)
    (check-equal? '(5 5) (list (car chosen) (selected)))
    (set! chosen (cdr chosen))))

(test "with no rows, motion and choosing do nothing"
  (ui:set-rows! b (lst) 0 number-row choose)
  (let ([before (length chosen)])
    (test-user:press! "C-n RET")
    (check-equal? (list #f '() before) (list (selected) (generations) (length chosen)))))

(test "a list's content is its rows: typing in it and editing it are refused"
  (ui:set-rows! b (lst) 2 number-row choose)
  (check-equal? '("the content does not fit here") (ui-test:report-messages (lambda () (test-user:press! "x"))))
  (check-raises (ui-test:raised? 'buffers:replace! "the node refuses the edit") (buffers:replace! b 1 2 ""))
  (check-raises (ui-test:raised? 'buffers:replace! "the node refuses the edit") (buffers:replace! b 1 1 (ui:list '()))))

(define t (buffers:make "*mixed*" (buffers:text '() "Pick:\n" (ui:list '()) "done\n")))
(define (mixed-list) (document:enclosing (buffers:document t) 8))
(define words (vector "one" "two"))

(test "a list inside a text buffer: outside it no row is selected and the list's keys are not active"
  (ui-test:show! t)
  (ui:set-rows! t (mixed-list) 2 (lambda (i) (ui:label (vector-ref words i))) (lambda (i) (choose (vector-ref words i))))
  (check-equal? #f (ui:selected-row (mixed-list) (view)))
  (check-equal? '("the cursor is in no list") (ui-test:report-messages (lambda () (views:with-view (view) (commands:run ui:next-row 1)))))
  (ui:select-row! (mixed-list) (view) 7)
  (check-equal? '(9 1) (list (views:point (view)) (ui:selected-row (mixed-list) (view))))
  (test-user:press! "C-p RET")
  (check-equal? "one" (car chosen)))

(test "the procedures check what they are given"
  (check-raises (ui-test:raised? 'ui:set-rows! "not a list of the buffer") (ui:set-rows! t (lst) 0 ui:label choose))
  (check-raises (ui-test:raised? 'ui:set-rows! "not a count") (ui:set-rows! t (mixed-list) (vector) ui:label choose))
  (check-raises (ui-test:raised? 'ui:set-rows! "not a count") (ui:set-rows! t (mixed-list) -1 ui:label choose))
  (check-raises (ui-test:raised? 'ui:set-rows! "not a procedure") (ui:set-rows! t (mixed-list) 0 number-row choose 'x))
  (check-raises (ui-test:raised? 'ui:add-rows! "not a count") (ui:add-rows! t (mixed-list) (vector)))
  (check-raises (ui-test:raised? 'ui:add-rows! "not a list of the buffer") (ui:add-rows! t (lst) 1))
  (check-raises (ui-test:raised? 'ui:select-row! "not a row index") (ui:select-row! (mixed-list) (view) -1))
  (check-raises (ui-test:raised? 'ui:selected-row "not a view") (ui:selected-row (mixed-list) 'view))
  (check-raises (ui-test:raised? 'ui:list-lines "not a buffer") (ui:list-lines 'b (mixed-list) 5))
  (check-raises (ui-test:raised? 'ui:list-lines "not a positive count") (ui:list-lines t (mixed-list) 0)))

(test "reloading ui keeps the rows in the buffer, and a list met afresh writes its rows under a generation past theirs"
  (let ([mixed-generations (lambda () (map (lambda (a) (cdr (assq 'generation (vector-ref a 1))))
                                           (cddr (car (document:datums (document:slice (buffers:document t) 7 11))))))])
    (check-equal? '(0 0) (mixed-generations))
    (reload-modules! '((ui)))
    (check-equal? '(0 0) (mixed-generations))
    (ui:set-rows! t (mixed-list) 2 (lambda (i) (ui:label (vector-ref words i))) choose)
    (check-equal? '(1 1) (mixed-generations))))

(test "once the maker of a list unloads, its rows draw as nothing: the first draw reports, later draws and RET call nothing"
  (load-module! '(ui-test maker))
  (ui-test:show! (buffers:find "*made*"))
  (check-equal? '("p!" "q!") (map car (rows-drawn (view))))
  (check-equal? '("module (ui-test maker) is unloaded")
    (ui-test:report-messages (lambda () (unload-owner! (module-owner '(ui-test maker))) (test-user:settle) (ui-test:drawn (view)))))
  (check-equal? '() (rows-drawn (view)))
  (check-equal? '() (ui-test:report-messages (lambda () (ui-test:drawn (view)) (test-user:press! "RET")))))

(test "the same holds for rows a command of the maker set"
  (load-module! '(ui-test maker-command))
  (test-user:press! "C-c m")
  (ui-test:show! (buffers:find "*made2*"))
  (check-equal? '("p!" "q!") (map car (rows-drawn (view))))
  (check-equal? '("module (ui-test maker-command) is unloaded")
    (ui-test:report-messages (lambda () (unload-owner! (module-owner '(ui-test maker-command))) (test-user:settle) (ui-test:drawn (view)))))
  (check-equal? '() (rows-drawn (view)))
  (check-equal? '() (ui-test:report-messages (lambda () (ui-test:drawn (view)) (test-user:press! "RET")))))

(define f (buffers:make "*failing*" (ui:list '())))
(define (failing) (document:token (buffers:document f) 0))
(define (picky n) (if (= n 1) (error 'picky "no row one") (number-row n)))

(test "a draw procedure that raises makes the list draw nothing until its rows are set again"
  (ui-test:show! f)
  (ui:set-rows! f (failing) 3 picky choose)
  (check-equal? '("no row one") (ui-test:report-messages (lambda () (ui-test:drawn (view)))))
  (check-equal? '() (rows-drawn (view)))
  (ui:set-rows! f (failing) 2 (lambda (i) (picky (* 2 i))) choose)
  (check-equal? '(("0" "true" clickable) ("2" #f clickable)) (rows-drawn (view))))

(test "a choose procedure that raises is reported by the command that ran it; the list then draws and chooses nothing until set again"
  (ui:set-rows! f (failing) 2 number-row (lambda (n) (error 'refuse "not this one")))
  (check-equal? '("not this one") (ui-test:report-messages (lambda () (test-user:press! "RET"))))
  (check-equal? '() (rows-drawn (view)))
  (check-equal? '() (ui-test:report-messages (lambda () (test-user:press! "RET"))))
  (ui:set-rows! f (failing) 2 number-row choose)
  (test-user:press! "RET")
  (check-equal? 0 (car chosen)))

(test "a list with no rows describes nothing, and describe-list takes a list of the view's buffer"
  (let ([e (buffers:make "*empty*" (ui:list '()))])
    (views:set-buffer! (view) e)
    (check-equal? #f (ui:describe-list (document:token (buffers:document e) 0) (view)))
    (check-raises (ui-test:raised? 'ui:describe-list "not a list of the buffer") (ui:describe-list (lst) (view)))
    (check-equal? 0 (ui:list-lines e (document:token (buffers:document e) 0) 5))))

(define h (buffers:make "*headed*" (ui:list '())))
(define (hl) (document:token (buffers:document h) 0))
(define (band n) (cond [(< n 3) "low"] [(< n 9) "mid"] [else "high"]))
(define (headings v) (map test-user:element-text (ui-test:elements v "ui-list-heading")))

(test "a heading is drawn above each row whose heading differs from the row before's, and above the first row a view draws"
  (ui-test:show! h)
  (ui:set-rows! h (hl) 12 number-row choose band)
  (check-equal? '("low" "mid" "high") (headings (view))))

(test "a heading is drawn beside its row's element, which carries the row's position and the cursor, not inside it"
  (ui:select-row! (hl) (view) 3)
  (let* ([drawn (ui-test:drawn (view))]
         [heading (find (lambda (e) (equal? "mid" (test-user:element-text e))) (test-user:elements drawn "ui-list-heading"))]
         [row-holders (filter (lambda (e) (pair? (test-user:elements e "ui-list-row"))) (test-user:elements-with drawn "data-at"))])
    (check (for-all (lambda (e) (null? (test-user:elements e "ui-list-heading"))) row-holders))
    (check-equal? 'li (car heading))))

(test "a press and a release on a heading name the list's own node, so they choose nothing and leave point; a click on a row chooses it"
  (set! chosen '())
  (ui:select-row! (hl) (view) 5)
  (let ([p0 (views:point (view))])
    (ui-test:mouse! (view) "down" (list (cons "token" (document:node-start (hl)))))
    (check-equal? (list '() 5 #t) (list chosen (ui:selected-row (hl) (view)) (= p0 (views:point (view)))))
    (ui-test:mouse! (view) "click" (list (cons "token" (document:node-start (hl)))))
    (check-equal? (list '() 5 #t) (list chosen (ui:selected-row (hl) (view)) (= p0 (views:point (view))))))
  (ui-test:click-token! (view) 7)
  (check-equal? '((6) 6) (list chosen (ui:selected-row (hl) (view))))
  (set! chosen '()))

(test "the first row a view draws inside a group names the group"
  (ui:set-rows! h (hl) 1000 number-row choose (lambda (i) (string-append "from " (number->string (* 100 (quotient i 100))))))
  (ui:select-row! (hl) (view) 550)
  (check-equal? '("from 400" "from 500" "from 600") (headings (view))))

(test "list-lines gives the lines the first rows and their headings take, at most the count given"
  (ui:set-rows! h (hl) 3 (lambda (i) (number-row (vector-ref (vector 0 1 3) i))) choose (lambda (i) (band (vector-ref (vector 0 1 3) i))))
  (check-equal? '(5 5) (list (ui:list-lines h (hl) 5) (ui:list-lines h (hl) 10)))
  (ui:set-rows! h (hl) 3 number-row choose (lambda (i) (band (vector-ref (vector 0 3 9) i))))
  (check-equal? '(5 4) (list (ui:list-lines h (hl) 5) (ui:list-lines h (hl) 4)))
  (ui:set-rows! h (hl) 2 number-row choose)
  (check-equal? '(() 2) (list (headings (view)) (ui:list-lines h (hl) 10))))

(test "a heading procedure that returns neither a string nor #f fails the list as a draw procedure does"
  (ui:set-rows! h (hl) 2 number-row choose (lambda (n) 'x))
  (check-equal? '((ui:set-rows! "a heading procedure returned neither a string nor #f" (x)))
    (map (lambda (c) (list (condition-who c) (condition-message c) (condition-irritants c)))
         (ui-test:reports-during (lambda () (ui-test:drawn (view))))))
  (check-equal? '() (rows-drawn (view))))

(test "a list made with (click . select) leaves clicks to the keymaps around it: a click moves point to the row and chooses nothing"
  (let* ([picked '()] [sl (buffers:make "*select*" (ui:list '((click . select))))])
    (ui:set-rows! sl (document:token (buffers:document sl) 0) 3 number-row (lambda (i) (set! picked (cons i picked))))
    (ui-test:show! sl)
    (ui-test:click-token! (view) 3)
    (check-equal? '(2 ()) (list (ui:selected-row (document:token (buffers:document sl) 0) (view)) picked))
    (test-user:press! "RET")
    (check-equal? '(2) picked)
    (check-equal? '(("0" #f #f) ("1" #f #f) ("2" "true" #f)) (rows-drawn (view)))
    (check-equal? #f (ui-test:mark-state (car (ui-test:elements (view) "ui-list"))))))

(test "a click attribute other than choose and select is refused"
  (let ([bad (buffers:make "*bad*" (ui:list '((click . chose))))])
    (check-raises (ui-test:raised? 'ui:set-rows! "a list's click is neither choose nor select")
      (ui:set-rows! bad (document:token (buffers:document bad) 0) 1 number-row (lambda (i) i)))))

(test "the list's keymaps: list-keys moves and chooses, row-keys chooses, list-click-keys ignores"
  (check-equal? (list (cons "C-n" ui:next-row) (cons "<down>" ui:next-row) (cons "C-p" ui:previous-row) (cons "<up>" ui:previous-row)
                      (cons "RET" ui:choose-row))
    (keys:bindings ui:list-keys))
  (check-equal? (list (cons "<mouse-1>" ui:choose-row) (cons "<mouse-2>" ui:choose-row)) (keys:bindings ui:row-keys))
  (check (for-all (lambda (b) (eq? keys:ignore (cdr b))) (keys:bindings ui:list-click-keys))))

(test "a click names a position on the screen it was drawn on: a row gone since is a stale click and runs nothing"
  (let ([r (buffers:make "*stale*" (ui:list '()))] [labels (lambda (v) (lambda (i) (ui:label (vector-ref v i))))])
    (set! chosen '())
    (ui-test:show! r)
    (ui:set-rows! r (document:token (buffers:document r) 0) 3 (labels (vector "a" "b" "c")) choose)
    (let ([drawn (buffers:version r)])
      (ui:set-rows! r (document:token (buffers:document r) 0) 3 (labels (vector "x" "y" "z")) choose)
      (check-equal? '("Stale click: what was clicked is gone")
        (ui-test:report-messages (lambda () (ui-test:mouse! (view) "click" '(("token" . 2)) (cons "version" drawn)))))
      (check-equal? '() chosen))
    (ui:set-rows! r (document:token (buffers:document r) 0) 3 number-row choose)
    (let ([drawn (buffers:version r)])
      (ui:add-rows! r (document:token (buffers:document r) 0) 17)
      (ui-test:mouse! (view) "click" '(("token" . 3)) (cons "version" drawn))
      (check-equal? '(2) chosen))))
