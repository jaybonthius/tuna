(import (tuna) (test) (test-user) (layout) (layout-split) (layout-tabs) (layout-scroll) (layout-float) (editing) (undo)
        (views) (buffers) (document) (keys) (options) (ask) (tables)
        (layout-test parts))

(define atom layout-test/parts:atom)
(define part layout-test/parts:part)
(define outline-of layout-test/parts:outline-of)

(define (view name) (views:make (or (buffers:find name) (buffers:make name (string-append name "\n")))))

(define (main-datum)
  (let ([p (caddr (layout-test/parts:tree))])
    (if (and (pair? p) (eq? (car p) 'layout-split:container) (pair? (caddr p)) (eq? (car (caddr p)) 'layout:level))
        (caddr (caddr p))
        p)))

(define (main) (outline-of (main-datum)))

(define (selected) (layout-test/parts:selected-name))

(define (outlined client class)
  (test-user:settle)
  (map layout-test/parts:class-names (test-user:elements (test-user:screen client) class)))

(define desktop (test-user:client))
(define phone (test-user:open-client))

(define notes #f)

(define (start-three!)
  (set! notes (buffers:make (buffers:free-name "notes") "one\n"))
  (let ([v1 (view "v1")] [v2 (views:make notes)] [v3 (view "v3")])
    (layout-test/parts:set-parts!
      (layout-split:container '((direction . row)) (atom v1) (layout-split:container '((direction . column)) (atom v2) (atom v3))))
    (layout:select! v2)
    (values v1 v2 v3)))

(test "C-x w w enters the part mode too, and the mode is shared: one client's keys move the part another entered with"
  (start-three!)
  (test-user:press! desktop "C-x w w")
  (test-user:press! phone "i")
  (check (layout:part-mode?))
  (check-equal? (list 'layout-split:container (buffers:name notes) "v3") (part)))

(test "a key the mode does not bind leaves it and runs in the selected view, so typing edits the view's buffer, never the layout"
  (start-three!)
  (test-user:press! desktop "C-x w w")
  (test-user:press! phone "z")
  (check (not (layout:part-mode?)))
  (check-equal? "zone\n" (document:text (buffers:document notes)))
  (check-equal? (list 'layout-split:container "v1" (list 'layout-split:container (buffers:name notes) "v3")) (main)))

(test "a key sequence leaves the mode at the first key the mode does not continue, so C-x 3 splits the selected view"
  (start-three!)
  (test-user:press! desktop "C-x w w C-x 3")
  (check (not (layout:part-mode?)))
  (check-equal? (list 'layout-split:container "v1"
                  (list 'layout-split:container (list 'layout-split:container (buffers:name notes) (buffers:name notes)) "v3"))
                (main)))

(test "window changes have no undo: C-/ leaves the mode and undoes the selected view's buffer"
  (start-three!)
  (test-user:press! "z")
  (let ([before (main)] [said '()])
    (options:set! ask:message-writer (lambda (text) (set! said (cons text said))))
    (test-user:press! "C-x w w C-/")
    (options:unset! ask:message-writer)
    (check (not (layout:part-mode?)))
    (check-equal? before (main))
    (check-equal? "one\n" (document:text (buffers:document notes)))
    (check-equal? '("Undo") said)))

(test "C-g, ESC and a click leave the mode"
  (let-values ([(v1 v2 v3) (start-three!)])
    (test-user:press! "C-x w w C-g")
    (check (not (layout:part-mode?)))
    (test-user:press! "C-x w w ESC")
    (check (not (layout:part-mode?)))
    (test-user:press! "C-x w w")
    (test-user:click! v1 1)
    (check (not (layout:part-mode?)))
    (check (eq? v1 (layout:selected-view)))))

(test "the selected part is outlined on every client while the mode is on, and the selected view's level too"
  (let-values ([(v1 v2 v3) (start-three!)])
    (layout:select! v1)
    (test-user:press! "C-x w w i")
    (check-equal? '(("split" "row" "part-selected" "focus-path")) (outlined desktop "part-selected"))
    (check-equal? '(("split" "row" "part-selected" "focus-path")) (outlined phone "part-selected"))
    (test-user:press! "k")
    (check-equal? '(("layout-view" "selected" "part-selected")) (outlined desktop "part-selected"))
    (check-equal? '(("layout-level" "part-level" "focus-path")) (outlined desktop "part-level"))
    (test-user:press! "RET")
    (check-equal? '() (outlined phone "part-selected"))
    (check-equal? '() (outlined phone "part-level"))
    (layout-test/parts:set-parts!
      (layout-split:container '((direction . row)) (atom v1)
        (layout:level '() (layout-split:container '((direction . column)) (atom v2) (atom v3)))))
    (layout:select! v3)
    (test-user:press! "s-'")
    (check-equal? '(("layout-level" "part-level" "focus-path")) (outlined desktop "part-level"))
    (check-equal? 2 (length (outlined desktop "layout-level")))
    (test-user:press! "RET")))

(test "while the mode is on, its keymap comes before the selected view's on the focus path"
  (start-three!)
  (check (not (memq layout:part-mode-keymap (layout:cursor-keymaps desktop #f))))
  (test-user:press! "s-'")
  (check (eq? layout:part-mode-keymap (car (layout:cursor-keymaps desktop #f))))
  (test-user:press! "RET"))

(test "a user rebinds the mode's keys in its keymap"
  (start-three!)
  (keys:bind! layout:part-mode-keymap "q" layout:part-mode-leave)
  (test-user:press! "s-' q")
  (check (not (layout:part-mode?)))
  (tables:remove! layout:part-mode-keymap "q"))

(define (start-five!)
  (let ([vs (map view '("a1" "a2" "a3" "a4" "a5"))])
    (layout-test/parts:set-parts!
      (layout-split:container '((direction . row)) (atom (list-ref vs 0))
        (layout-split:container '((direction . column)) (atom (list-ref vs 1)) (atom (list-ref vs 2)) (atom (list-ref vs 3)))
        (atom (list-ref vs 4))))
    (layout:select! (list-ref vs 2))
    vs))

(define column '(layout-split:container "a2" "a3" "a4"))

(test "outside the mode the selected part is the selected view's atom; s-' enters with it selected, for every client"
  (start-five!)
  (check-equal? '(#f "a3") (list (layout:part-mode?) (part)))
  (test-user:press! desktop "s-'")
  (check-equal? '(#t "a3") (list (layout:part-mode?) (part)))
  (test-user:press! "RET"))

(test "i selects the container and the selected view stays; j and l select the parts before and after, and focus follows"
  (start-five!)
  (test-user:press! desktop "s-'")
  (test-user:press! phone "i")
  (check-equal? (list column "a3") (list (part) (selected)))
  (test-user:press! "l")
  (check-equal? '("a5" "a5") (list (part) (selected)))
  (test-user:press! "j j")
  (check-equal? '("a1" "a1") (list (part) (selected)))
  (test-user:press! "j")
  (check-equal? "a1" (part))
  (test-user:press! "RET"))

(test "k selects the focused child, so i then k comes back; the arrows move as i, j, k and l; 0 and $ select the ends"
  (start-five!)
  (test-user:press! "s-' l k l")
  (check-equal? '("a4" "a4") (list (part) (selected)))
  (test-user:press! "i k")
  (check-equal? '("a4" "a4") (list (part) (selected)))
  (test-user:press! "<up> <right> <left> <down>")
  (check-equal? '("a4" "a4") (list (part) (selected)))
  (test-user:press! "0")
  (check-equal? "a2" (part))
  (test-user:press! "$")
  (check-equal? "a4" (part))
  (test-user:press! "RET"))

(test "levels are parts the mode visits, and so is a part placed outside them; the root's part has no parent and no siblings; k on a view does nothing"
  (start-five!)
  (layout-test/parts:place-echo! (buffers:make (buffers:free-name "*Echo*") ""))
  (let ([whole (list 'layout-split:container (list 'layout:level (list 'layout-split:container "a1" column "a5"))
                     (layout-test/parts:name-of (car (last-pair (layout:views)))))])
    (test-user:press! "s-' $ i i i i")
    (check-equal? whole (part))
    (test-user:press! "l j 0 $")
    (check-equal? whole (part))
    (test-user:press! "k k k k")
    (check-equal? "a4" (part))
    (test-user:press! "RET")))

(test "a locked part is selected but takes no focus"
  (let ([vs (map view '("a1" "a2" "a3"))] [echo-buffer (buffers:make (buffers:free-name "*Echo*") "")])
    (layout-test/parts:set-parts!
      (layout-split:container '((direction . column))
        (layout:level '() (layout-split:container '((direction . row)) (atom (car vs)) (atom (cadr vs) '(locked . #t)) (atom (caddr vs))))
        (atom (views:make echo-buffer) '(depth . 90) '(size . content) '(locked . #t))))
    (layout:select! (car vs))
    (test-user:press! "s-' l")
    (check-equal? '("a2" "a1") (list (part) (selected)))
    (test-user:press! "l")
    (check-equal? '("a3" "a3") (list (part) (selected)))
    (test-user:press! "j j")
    (check-equal? '("a1" "a1") (list (part) (selected)))
    (test-user:press! "i i l")
    (check-equal? (list (buffers:name echo-buffer) "a1") (list (part) (selected)))
    (test-user:press! "RET")))

(test "popups are not parts of the layout: from a popup, s-' selects the root's part"
  (let ([vs (start-five!)])
    (let ([p (layout-float:show-at! (car vs) 0 (buffers:make (buffers:free-name "popup") "") 1/2 1/2)])
      (layout:select! p)
      (test-user:press! "s-'")
      (check-equal? (main) (part))
      (layout:select! (caddr vs))
      (test-user:press! "RET")
      (check-equal? '(#f "a3") (list (layout:part-mode?) (part)))
      (layout-float:close! p))))

(test "the moves work outside the mode too, from the selected view's atom, and a locked part before it takes no focus"
  (let ([vs (map view '("a1" "a2" "a3"))])
    (layout-test/parts:set-parts!
      (layout-split:container '((direction . row)) (atom (car vs)) (atom (cadr vs) '(locked . #t)) (atom (caddr vs))))
    (layout:select! (caddr vs))
    (layout:select-previous)
    (check-equal? "a3" (selected))
    (layout:select-parent)
    (check-equal? '(#f "a3" "a3") (list (layout:part-mode?) (part) (selected)))))

(define (example! selected-name)
  (layout:part-mode-leave)
  (let ([vs (map (lambda (name) (cons name (view name))) '("files" "main.ss" "*shell*" "notes.org" "*magit*" "*help*"))])
    (define (v name) (cdr (assoc name vs)))
    (layout-test/parts:set-parts!
      (layout-split:container '((direction . column))
        (layout:level '()
          (layout-split:container '((direction . row))
            (atom (v "files") '(weight . 1))
            (layout-scroll:container '((direction . row) (weight . 3))
              (layout-split:container '((direction . column) (size . 1/2)) (atom (v "main.ss")) (atom (v "*shell*")))
              (atom (v "notes.org") '(size . 1/2))
              (layout-float:container '((size . 1/2)) (atom (v "*magit*") '(place box 1/4 1/4)) (atom (v "*help*") '(place box 3/4 3/4))))))
        (atom (view "*Echo*") '(depth . 90) '(size . content) '(locked . #t))))
    (layout:select! (v selected-name))))

(define (strip-datum) (cadddr (main-datum)))
(define (strip) (outline-of (strip-datum)))

(define desk '(layout-float:container "*magit*" "*help*"))
(define split '(layout-split:container "main.ss" "*shell*"))

(test "with main.ss selected, s-' i L L RET moves its whole column along the strip, keeping its size, and s-' i J J RET moves it back"
  (example! "main.ss")
  (test-user:press! "s-' i L")
  (check-equal? (list 'layout-scroll:container "notes.org" split desk) (strip))
  (test-user:press! "L")
  (check-equal? (list 'layout-scroll:container "notes.org" desk split) (strip))
  (check-equal? '(layout-split:container ((direction . column) (size . 1/2))) (list-head (car (last-pair (strip-datum))) 2))
  (test-user:press! "RET")
  (check-equal? '(#f "main.ss") (list (layout:part-mode?) (selected)))
  (test-user:press! "s-' i J J RET")
  (check-equal? (list 'layout-scroll:container split "notes.org" desk) (strip)))

(test "s-' J K L L moves notes.org into the first column, below *shell*, keeping its size, which a split names too"
  (example! "notes.org")
  (test-user:press! "s-' J K L L")
  (check-equal? '(layout-split:container "main.ss" "*shell*" "notes.org") (outline-of (caddr (strip-datum))))
  (check-equal? '((size . 1/2)) (cddr (layout-test/parts:attributes-of (find (lambda (v) (equal? "notes.org" (layout-test/parts:name-of v))) (layout:views)))))
  (test-user:press! "RET"))

(test "s-' w t wraps main.ss in tabs inside its column; s-' i - dissolves the column into two columns sharing its size"
  (example! "main.ss")
  (test-user:press! "s-' w t")
  (check-equal? '(layout-split:container (layout-tabs:container "main.ss") "*shell*") (outline-of (caddr (strip-datum))))
  (example! "main.ss")
  (test-user:press! "s-' i -")
  (check-equal? (list 'layout-scroll:container "main.ss" "*shell*" "notes.org" desk) (strip))
  (check-equal? '((size . 1/4) (size . 1/4))
                (map (lambda (d) (caddr (vector-ref d 1))) (list-head (cddr (strip-datum)) 2)))
  (test-user:press! "RET"))

(test "s-' l selects the float desktop and focuses its first float; l selects the next, which rises, as floats stack by their last selection"
  (example! "notes.org")
  (test-user:press! "s-' l")
  (check-equal? (list desk "*magit*") (list (part) (selected)))
  (test-user:press! "k l")
  (check-equal? '("*help*" "*help*" ("*help*" "*magit*"))
                (list (part) (selected) (map layout-test/parts:name-of (list-head (layout:selection-order) 2))))
  (test-user:press! "RET"))

(test "s-' K L L K moves files into the strip as a column of the default size, past two columns, and onto the desktop, where it floats in the middle"
  (example! "files")
  (test-user:press! "s-' K")
  (check-equal? 'layout-scroll:container (car (main)))
  (check-equal? "files" (cadr (main)))
  (test-user:press! "L L K")
  (check-equal? (list 'layout-scroll:container split "notes.org" '(layout-float:container "files" "*magit*" "*help*")) (main))
  (check-equal? '((place box 1/2 1/2))
                (cddr (layout-test/parts:attributes-of (find (lambda (v) (equal? "files" (layout-test/parts:name-of v))) (layout:views)))))
  (test-user:press! "RET"))
