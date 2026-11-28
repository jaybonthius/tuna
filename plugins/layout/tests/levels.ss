(import (tuna) (test) (test-runner) (test-user) (layout) (layout-split) (layout-tabs) (views) (buffers) (document) (commands)
        (layout-test parts))

(define named layout-test/parts:named)
(define atom layout-test/parts:atom)
(define names layout-test/parts:names)
(define selected-name layout-test/parts:selected-name)

(define notes #f)
(define pi #f)
(define echo #f)
(define explorer #f)

(define (start!)
  (set! notes (views:make (named "notes.org")))
  (set! pi (views:make (named "*pi*")))
  (layout-test/parts:set-parts! (layout-split:container '((direction . row)) (atom notes) (atom pi)))
  (layout:select! notes)
  (set! echo (layout-test/parts:place-echo! (named " *Echo Area*")))
  (set! explorer (layout:display-buffer (named "*explorer*") (layout-split:display-at-side (layout:direction left) 50 '(columns 30)))))

(define (classes-of client class)
  (map layout-test/parts:class-names (test-user:elements (test-user:screen client) class)))

(test "placing parts at the sides wraps the user's windows in a level; the placed parts are outside it, in the root's level"
  (start!)
  (check-equal? '(layout:level
                  (layout-split:container
                    (layout-split:container "*explorer*" (layout:level (layout-split:container "notes.org" "*pi*")))
                    " *Echo Area*"))
                (layout-test/parts:outline))
  (check-equal? '("*explorer*" "notes.org" "*pi*" " *Echo Area*") (names))
  (check (eq? (layout:level-of notes) (layout:level-of pi)))
  (check (eq? (layout:level-of explorer) (layout:level-of echo)))
  (check-equal? 0 (document:node-start (layout:level-of explorer))))

(test "each part's element carries the classes kinds draw by, and outside a draw part-class gives none"
  (start!)
  (test-user:settle)
  (let ([c (test-user:client)])
    (check-equal? '(("layout-level" "focus-path") ("layout-level" "focus-path")) (classes-of c "layout-level"))
    (check-equal? '(("split" "column" "frame" "focus-path") ("split" "row" "frame" "focus-path") ("split" "row" "focus-path"))
                  (classes-of c "split"))
    (check-equal? '(("layout-view" "placed") ("layout-view" "selected") ("layout-view") ("layout-view" "placed" "locked"))
                  (classes-of c "layout-view")))
  (check-equal? #f (layout:part-class (layout:view-node notes))))

(test "C-x 1 fills the selected view's level with it and keeps the parts outside; again shows everything; nothing is deleted"
  (start!)
  (test-user:press! "C-x 1")
  (check-equal? '("*explorer*" "notes.org" " *Echo Area*") (names))
  (check (eq? notes (layout:zoomed-view)))
  (test-user:press! "C-x 1")
  (check-equal? '("*explorer*" "notes.org" "*pi*" " *Echo Area*") (names))
  (check-equal? #f (layout:zoomed-view)))

(test "C-u C-x 1 fills the screen, M-2 C-x 1 fills the level two out, at most the root"
  (start!)
  (test-user:press! "C-u C-x 1")
  (check-equal? '("notes.org") (names))
  (test-user:press! "C-x 1")
  (test-user:press! "M-2 C-x 1")
  (check-equal? '("notes.org") (names))
  (test-user:press! "C-x 1")
  (layout:zoom '(4))
  (check-equal? '("notes.org") (names))
  (layout:zoom #f)
  (check-equal? '("*explorer*" "notes.org" "*pi*" " *Echo Area*") (names)))

(test "selecting a view the zoom shows keeps it, one it hides ends it; in a root-level part C-x 1 fills the screen"
  (start!)
  (test-user:press! "C-x 1")
  (layout:select! explorer)
  (check-equal? '("*explorer*" "notes.org" " *Echo Area*") (names))
  (check (eq? notes (layout:zoomed-view)))
  (layout:select! pi)
  (check-equal? '("*explorer*" "notes.org" "*pi*" " *Echo Area*") (names))
  (check-equal? #f (layout:zoomed-view))
  (layout:select! explorer)
  (test-user:press! "C-x 1")
  (check-equal? '("*explorer*") (names))
  (test-user:press! "C-x 1"))

(test "a view added to the zoomed level, as C-x 3 adds one, ends the zoom, so the new view shows; one added outside it keeps the zoom"
  (start!)
  (test-user:press! "C-x 1")
  (check-equal? '("*explorer*" "notes.org" " *Echo Area*") (names))
  (test-user:press! "C-x 3")
  (check-equal? #f (layout:zoomed-view))
  (check-equal? '("*explorer*" "notes.org" "notes.org" "*pi*" " *Echo Area*") (names))
  (check (eq? notes (layout:selected-view)))
  (test-user:press! "C-x 1")
  (layout-split:split-view! explorer (layout-split:direction column) (named "outside"))
  (check (eq? notes (layout:zoomed-view)))
  (check-equal? '("*explorer*" "outside" "notes.org" " *Echo Area*") (names))
  (test-user:press! "C-x 1"))

(test "C-x o goes round the selected view's level; from a part outside it the level counts as one view; the Super moves cross levels"
  (start!)
  (test-user:press! "C-x o")
  (check-equal? "*pi*" (selected-name))
  (test-user:press! "C-x o")
  (check-equal? "notes.org" (selected-name))
  (layout:select! explorer)
  (test-user:press! "C-x o")
  (check-equal? "notes.org" (selected-name))
  (test-user:press! "C-x o")
  (check-equal? "*pi*" (selected-name))
  (test-user:press! "s-<left>")
  (check-equal? "notes.org" (selected-name)))

(test "C-x 2 splits inside the level, and a display from a placed part lands among the level's views"
  (start!)
  (layout:select! pi)
  (test-user:press! "C-x 2")
  (check-equal? '(layout:level
                  (layout-split:container
                    (layout-split:container "*explorer*"
                      (layout:level (layout-split:container "notes.org" (layout-split:container "*pi*" "*pi*"))))
                    " *Echo Area*"))
                (layout-test/parts:outline))
  (layout:select! explorer)
  (let ([v (layout:use-other-view (named "mail"))])
    (check-equal? "mail" (layout-test/parts:name-of v))
    (check (not (eq? v explorer)))
    (check (eq? (layout:level-of v) (layout:level-of notes)))
    (check-equal? "*explorer*" (layout-test/parts:name-of explorer))))

(test "reset-layout deletes the other views of the selected view's level; from a placed part it deletes nothing"
  (start!)
  (layout:select! pi)
  (test-user:press! "C-x 2")
  (layout:select! notes)
  (commands:run layout:reset-layout)
  (check-equal? '(layout:level
                  (layout-split:container (layout-split:container "*explorer*" (layout:level "notes.org")) " *Echo Area*"))
                (layout-test/parts:outline))
  (layout:select! explorer)
  (let ([before (layout-test/parts:tree)])
    (commands:run layout:reset-layout)
    (check-equal? before (layout-test/parts:tree))))

(test "alone in its level a view does not zoom, though C-u C-x 1 fills the screen, and C-x 0 never empties a level"
  (start!)
  (layout:select! notes)
  (layout:delete-part! (layout:view-node pi))
  (check-raises (test-runner:raised-with 'layout:zoom "no other views in this level") (layout:zoom #f))
  (check-equal? '((layout:zoom "no other views in this level"))
                (test-runner:shown-reports-during (lambda () (test-user:press! "C-x 1"))))
  (check-equal? #f (layout:zoomed-view))
  (test-user:press! "C-u C-x 1")
  (check-equal? '("notes.org") (names))
  (test-user:press! "C-x 1")
  (check-equal? '((layout:delete-view "the last view of its level"))
                (test-runner:shown-reports-during (lambda () (test-user:press! "C-x 0"))))
  (check-equal? '("*explorer*" "notes.org" " *Echo Area*") (names)))

(test "C-x 0 in a placed part deletes it, and its split, left holding the level alone, collapses"
  (start!)
  (layout:select! explorer)
  (test-user:press! "C-x 0")
  (check-equal? '(layout:level (layout-split:container (layout:level (layout-split:container "notes.org" "*pi*")) " *Echo Area*"))
                (layout-test/parts:outline)))

(define work #f)
(define outline #f)
(define shell #f)

(define (start-tabs!)
  (start!)
  (set! work (views:make (named "work")))
  (set! outline (views:make (named "*outline*")))
  (set! shell (views:make (named "*shell*")))
  (set! pi (views:make (named "*pi*")))
  (layout-test/parts:set-parts!
    (layout-split:container '((direction . column))
      (layout:level '()
        (layout-tabs:container '()
          (atom work '(title . "work"))
          (layout-split:container '((direction . row) (title . "chat"))
            (atom outline '(size columns 24))
            (layout:level '() (layout-split:container '((direction . row)) (atom pi) (atom shell))))))
      (atom echo '(depth . 90) '(size . content) '(locked . #t))))
  (layout:select! pi))

(define (strip-drawn?)
  (test-user:settle)
  (pair? (test-user:elements (test-user:screen) "tabs-strip")))

(test "C-x 1 inside a tab fills the innermost level, keeping the tab strip; M-2 C-x 1 fills the tabs' level, strip and all"
  (start-tabs!)
  (check-equal? '("*outline*" "*pi*" "*shell*" " *Echo Area*") (names))
  (test-user:press! "C-x 1")
  (check-equal? '("*outline*" "*pi*" " *Echo Area*") (names))
  (check (strip-drawn?))
  (test-user:press! "C-x 1")
  (test-user:press! "M-2 C-x 1")
  (check-equal? '("*pi*" " *Echo Area*") (names))
  (check (not (strip-drawn?)))
  (test-user:press! "C-x 1"))

(test "C-x o stays in a nested level, and from beside it the level counts as one view"
  (start-tabs!)
  (test-user:press! "C-x o")
  (check-equal? "*shell*" (selected-name))
  (test-user:press! "C-x o")
  (check-equal? "*pi*" (selected-name))
  (layout:select! outline)
  (test-user:press! "C-x o")
  (check-equal? "*pi*" (selected-name)))

(test "reset-layout from beside a nested level deletes the level's other views, another tab's included, and keeps the nested level whole"
  (start-tabs!)
  (layout:select! outline)
  (commands:run layout:reset-layout)
  (check-equal? '(layout:level
                  (layout-split:container
                    (layout:level
                      (layout-tabs:container
                        (layout-split:container "*outline*" (layout:level (layout-split:container "*pi*" "*shell*")))))
                    " *Echo Area*"))
                (layout-test/parts:outline)))
