;;; The default layout's tree operations, which are pure: no kernel, no
;;; buffers provider. Views here are bare contract objects.
(import :std/test
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/tree)
(export tree-test)

(def fit (make-layout-kind 'fit "" #t #f void))
(def tabbed (make-layout-kind 'tabbed "" #f #t void))
(def (kind-of name) (if (eq? name 'tabbed) tabbed fit))

(def some-buffer (buffer id: 0))

(def (leaf-of id)
  (make-leaf (view id: id showing: some-buffer focus: #f position: 1 revision: 0 goal-column: #f
                   last-placement: (make-placement 0 #f 'top 0.) clients: (make-hash-table))
             #f))

(def (ids parts) (map part-id parts))

;; The tree's shape: leaf ids, and (kind direction focus (size shape) ...),
;; with `pinned` and `locked` after the size of a flagged link.
(def (shape p)
  (if (leaf? p)
    (part-id p)
    [(container-kind p) (container-direction p) (container-focus p)
     (map (lambda (l)
            (append [(link-size l)]
                    (if (link-pinned? l) '(pinned) '())
                    (if (link-locked? l) '(locked) '())
                    [(shape (link-part l))]))
          (container-links p))]))

(def (pin root id)
  (update-link root id (lambda (l) (make-link (link-size l) (link-part l) #t (link-locked? l)))))

(def (lock root id)
  (update-link root id (lambda (l) (make-link (link-size l) (link-part l) #t #t))))

;; 100 [fit horizontal: 1 | 200 [fit vertical: 2 / 3] | 300 [tabbed: 4, 5]]
(def (sample)
  (make-container 100 'fit 'horizontal
                  [(new-link 1 (leaf-of 1))
                   (new-link 2 (make-container 200 'fit 'vertical
                                                [(new-link 1 (leaf-of 2)) (new-link 1 (leaf-of 3))]
                                                3))
                   (new-link 1 (make-container 300 'tabbed 'horizontal
                                                [(new-link 1 (leaf-of 4)) (new-link 1 (leaf-of 5))]
                                                4))]
                  1))

(def tree-test
  (test-suite "tuna/plugins/layout/tree"
    (test-case "finding parts, paths, parents and leaves"
      (let (root (sample))
        (check (ids (part-leaves root)) => [1 2 3 4 5])
        (check (ids (part-path root 3)) => [100 200 3])
        (check (part-path root 9) => #f)
        (check (part-id (find-part root 300)) => 300)
        (check (container-id (parent-container root 5)) => 300)
        (check (parent-container root 100) => #f)
        (check (common-ancestor-id root [2 3]) => 200)
        (check (common-ancestor-id root [3 4]) => 100)
        (check (common-ancestor-id root [5]) => 5)
        (check (common-ancestor-id root [5 9]) => #f)))

    (test-case "focus memory: focused leaves, visible leaves, selecting a path"
      (let* ((root (sample))
             (selected (select-path root 5)))
        (check (part-id (focused-leaf root)) => 1)
        (check (part-id (focused-leaf (find-part root 200))) => 3)
        ;; A tabbed container shows only its focused child.
        (check (ids (visible-leaves root kind-of)) => [1 2 3 4])
        (check (ids (visible-leaves selected kind-of)) => [1 2 3 5])
        (check (part-id (focused-leaf selected)) => 5)
        (check (container-focus selected) => 300)
        ;; Parts off the path are shared; the old tree is unchanged.
        (check (eq? (find-part selected 200) (find-part root 200)) => #t)
        (check (container-focus root) => 1)
        (check (eq? (select-path selected 5) selected) => #t)))

    (test-case "splitting a view nests a new fit container, or halves its link"
      (let* ((root (sample))
             (new (leaf-of 6))
             (beside (split-part root 1 new 'vertical 400 kind-of))
             (below (split-part root 2 new 'vertical 400 kind-of)))
        (check (shape (find-part beside 400)) => ['fit 'vertical 1 [[1 1] [1 6]]])
        (check (link-size (car (container-links beside))) => 1)
        ;; Inside a fit container of the same direction: the link is halved.
        (check (shape (find-part below 200)) => ['fit 'vertical 3 [[1/2 2] [1/2 6] [1 3]]])
        (check (eq? (find-part below 300) (find-part root 300)) => #t)
        (check (shape (split-part (leaf-of 1) 1 new 'horizontal 7 kind-of))
               => ['fit 'horizontal 1 [[1 1] [1 6]]])))

    (test-case "removing parts collapses fit containers and moves their focus"
      (let* ((root (sample))
             (without-3 (remove-part root 3 kind-of))
             (without-5 (remove-part root 5 kind-of))
             (without-tabs (remove-part (remove-part without-5 4 kind-of) 1 kind-of)))
        ;; 200 collapses into 2, which takes its link and size.
        (check (shape without-3) => ['fit 'horizontal 1 [[1 1] [2 2] [1 ['tabbed 'horizontal 4 [[1 4] [1 5]]]]]])
        ;; A tabbed container keeps a single tab.
        (check (shape (find-part without-5 300)) => ['tabbed 'horizontal 4 [[1 4]]])
        (check (shape without-tabs) => ['fit 'vertical 3 [[1 2] [1 3]]])
        (check (remove-part (leaf-of 1) 1 kind-of) => #f)
        ;; A removed focused child passes the focus to its previous sibling.
        (check (container-focus (find-part (remove-part (select-path root 4) 4 kind-of) 300)) => 5)
        (check (container-focus (find-part (remove-part (select-path root 5) 5 kind-of) 300)) => 4)))

    (test-case "replacing a part keeps its link's size; inserting a link"
      (let* ((root (sample))
             (replaced (replace-part root 200 (leaf-of 7) kind-of))
             (inserted (insert-link root 300 '(after . 4) (new-link 1 (leaf-of 8)))))
        (check (shape replaced) => ['fit 'horizontal 1 [[1 1] [2 7] [1 ['tabbed 'horizontal 4 [[1 4] [1 5]]]]]])
        (check (ids (part-leaves (find-part inserted 300))) => [4 8 5])))

    (test-case "wrapping a part: the new container takes its link, the part gets size 1 and no flags"
      (let* ((root (pin (sample) 200))
             (column (wrap-part root 200 'tabbed 'vertical 400))
             (view (wrap-part root 1 'fit 'vertical 400)))
        (check (shape column)
               => ['fit 'horizontal 1
                   [[1 1]
                    [2 'pinned ['tabbed 'vertical 200 [[1 ['fit 'vertical 3 [[1 2] [1 3]]]]]]]
                    [1 ['tabbed 'horizontal 4 [[1 4] [1 5]]]]]])
        (check (car (cadddr (shape view))) => [1 ['fit 'vertical 1 [[1 1]]]])
        ;; The wrapped part and the parts off the path are shared.
        (check (eq? (find-part column 200) (find-part root 200)) => #t)
        (check (eq? (find-part column 300) (find-part root 300)) => #t)
        (check (ids (part-path column 3)) => [100 400 200 3])
        (check (part-id (focused-leaf (find-part view 400))) => 1)))

    (test-case "wrapping the root makes the new container the root; a locked part's lock moves to its wrapper"
      (let* ((root (sample))
             (wrapped (wrap-part root 100 'tabbed 'horizontal 400))
             (locked (wrap-part (lock root 300) 300 'fit 'vertical 400)))
        (check (shape wrapped) => ['tabbed 'horizontal 100 [[1 (shape root)]]])
        (check (eq? (link-part (car (container-links wrapped))) root) => #t)
        (check (part-link wrapped 400) => #f)
        (check (shape (find-part locked 100))
               => ['fit 'horizontal 1
                   [[1 1] [2 ['fit 'vertical 3 [[1 2] [1 3]]]]
                    [1 'pinned 'locked ['fit 'vertical 300 [[1 ['tabbed 'horizontal 4 [[1 4] [1 5]]]]]]]]])
        (check (inside-locked? locked 300) => #t)
        (check (link-locked? (part-link locked 300)) => #f)))

    (test-case "a wrapper with one child stays until a removal empties it; a removal leaving one child collapses"
      (let* ((root (wrap-part (sample) 1 'fit 'vertical 400))
             (split (split-part root 1 (leaf-of 6) 'horizontal 500 kind-of))
             (beside (split-part root 1 (leaf-of 6) 'vertical 500 kind-of))
             (moved (move-part root 2 'vertical #t kind-of)))
        ;; A change inside it, across its direction, nests a container in it.
        (check (shape (find-part split 400)) => ['fit 'vertical 500 [[1 ['fit 'horizontal 1 [[1 1] [1 6]]]]]])
        ;; Along its direction, the part's link is halved inside it.
        (check (shape (find-part beside 400)) => ['fit 'vertical 1 [[1/2 1] [1/2 6]]])
        ;; A change elsewhere leaves it alone.
        (check (shape (find-part moved 400)) => ['fit 'vertical 1 [[1 1]]])
        ;; Removing a child it was given collapses it again.
        (check (car (cadddr (shape (remove-part beside 6 kind-of)))) => [1 1])
        (check (find-part (remove-part root 1 kind-of) 400) => #f)))

    (test-case "changing a container's kind and direction keeps its children, their links and its focus"
      (let* ((root (select-path (pin (sample) 3) 3))
             (tabbed (reshape-container root 200 'tabbed 'vertical))
             (fit (reshape-container root 300 'fit 'vertical))
             (turned (reshape-container root 100 'fit 'vertical)))
        (check (shape (find-part tabbed 200)) => ['tabbed 'vertical 3 [[1 2] [1 'pinned 3]]])
        (check (link-size (part-link tabbed 200)) => 2)
        (check (ids (visible-leaves tabbed kind-of)) => [1 3 4])
        (check (shape (find-part fit 300)) => ['fit 'vertical 4 [[1 4] [1 5]]])
        (check (ids (visible-leaves fit kind-of)) => [1 2 3 4 5])
        (check (shape turned) => (cons* 'fit 'vertical (cddr (shape root))))
        (check (andmap eq? (container-links turned) (container-links root)) => #t)
        ;; A single tab made a fit container keeps its one child.
        (let (single (reshape-container (remove-part root 5 kind-of) 300 'fit 'horizontal))
          (check (shape (find-part single 300)) => ['fit 'horizontal 4 [[1 4]]])
          (check (shape (find-part (move-part single 2 'vertical #t kind-of) 300))
                 => ['fit 'horizontal 4 [[1 4]]]))
        (check-exception (reshape-container root 1 'fit 'vertical) true)))

    (test-case "neighbors cross spatial containers of the right direction, by focus memory"
      (let* ((root (sample))
             (remembered (select-path (select-path root 2) 1)))
        (check (part-id (neighbor-leaf root 1 'horizontal #t kind-of)) => 3)
        (check (part-id (neighbor-leaf remembered 1 'horizontal #t kind-of)) => 2)
        (check (part-id (neighbor-leaf root 2 'horizontal #f kind-of)) => 1)
        (check (part-id (neighbor-leaf root 3 'horizontal #t kind-of)) => 4)
        (check (part-id (neighbor-leaf root 2 'vertical #t kind-of)) => 3)
        (check (neighbor-leaf root 3 'vertical #t kind-of) => #f)
        (check (neighbor-leaf root 1 'horizontal #f kind-of) => #f)
        ;; Tabs are not side by side.
        (check (neighbor-leaf root 4 'horizontal #t kind-of) => #f)
        ;; Inside TOP only.
        (check (neighbor-leaf (find-part root 200) 2 'horizontal #f kind-of) => #f)))

    (test-case "drawing under zoom: the child on the way and the pinned children of each container"
      (let* ((root (sample))
             (pinned (pin (pin root 3) 300)))
        ;; Without pins, the target alone; with no zoom, everything.
        (check (part-id (drawn-part root 2)) => 2)
        (check (eq? (drawn-part pinned 100) pinned) => #t)
        ;; Several pins: 3 beside 2 in their column, and the tabs beside the
        ;; column, which takes the weight of 1, left out, as well as its own.
        (check (shape (drawn-part pinned 2))
               => ['fit 'horizontal 200
                   [[3 ['fit 'vertical 2 [[1 2] [1 'pinned 3]]]]
                    [1 'pinned ['tabbed 'horizontal 4 [[1 4] [1 5]]]]]])
        (check (ids (visible-leaves (drawn-part pinned 2) kind-of)) => [2 3 4])
        ;; The child on the way takes what the pinned children leave,
        ;; however big they are.
        (let (sized (update-link pinned 300 (lambda (l) (make-link 'content (link-part l) #t #f))))
          (check (link-size (car (container-links (drawn-part sized 2)))) => 3)
          (check (link-size (cadr (container-links (drawn-part sized 2)))) => 'content))))

    (test-case "zooming into a tab with a pinned sibling tab shows both tabs, the zoomed one active"
      (let* ((root (pin (sample) 5))
             (drawn (drawn-part root 4)))
        (check (shape drawn) => ['tabbed 'horizontal 4 [[1 4] [1 'pinned 5]]])
        (check (ids (visible-leaves drawn kind-of)) => [4])
        ;; Zoomed onto the pinned tab itself, its unpinned sibling hides.
        (check (part-id (drawn-part root 5)) => 5)))

    (test-case "the frame's target inside a pinned part follows the same rule"
      (let* ((root (pin (pin (sample) 300) 1))
             (drawn (drawn-part root 5)))
        (check (shape drawn) => ['fit 'horizontal 300 [[1 'pinned 1] [3 'pinned 5]]])
        (check (ids (visible-leaves drawn kind-of)) => [1 5])))

    (test-case "moving a part past a sibling, into a neighbor container, or out of its container"
      (let (root (sample))
        ;; Past a sibling: the same in a fit column and among tabs.
        (check (shape (find-part (move-part root 2 'vertical #t kind-of) 200))
               => ['fit 'vertical 3 [[1 3] [1 2]]])
        (check (shape (find-part (move-part root 4 'horizontal #t kind-of) 300))
               => ['tabbed 'horizontal 4 [[1 5] [1 4]]])
        ;; Into a neighbor container, at the near end.
        (check (shape (move-part root 1 'horizontal #t kind-of))
               => ['fit 'horizontal 1 [[2 ['fit 'vertical 3 [[1 1] [1 2] [1 3]]]]
                                       [1 ['tabbed 'horizontal 4 [[1 4] [1 5]]]]]])
        ;; Out of a column across the axis, beside it; the column collapses
        ;; into its other child, which keeps the column's link.
        (check (shape (move-part root 2 'horizontal #f kind-of))
               => ['fit 'horizontal 1 [[1 1] [1 2] [2 3] [1 ['tabbed 'horizontal 4 [[1 4] [1 5]]]]]])
        ;; Out of the tabs at their edge; they keep their single tab.
        (check (shape (move-part root 5 'horizontal #t kind-of))
               => ['fit 'horizontal 1 [[1 1] [2 ['fit 'vertical 3 [[1 2] [1 3]]]]
                                       [1 ['tabbed 'horizontal 4 [[1 4]]]] [1 5]]])
        ;; No container of that direction above: it cannot move.
        (check (move-part root 3 'vertical #t kind-of) => #f)
        (check (move-part root 1 'horizontal #f kind-of) => #f)
        (check (move-part root 100 'horizontal #t kind-of) => #f)))

    (test-case "a moved part keeps its link: size, pin and lock"
      (let* ((root (lock (pin (sample) 2) 300))
             (moved (move-part root 2 'horizontal #f kind-of)))
        (check (shape moved)
               => ['fit 'horizontal 1 [[1 1] [1 'pinned 2] [2 3] [1 'pinned 'locked ['tabbed 'horizontal 4 [[1 4] [1 5]]]]]])
        (check (shape (move-part moved 300 'horizontal #f kind-of))
               => ['fit 'horizontal 1 [[1 1] [1 'pinned 2] [1 'pinned 'locked ['tabbed 'horizontal 4 [[1 4] [1 5]]]] [2 3]]])))

    (test-case "locks: inside a locked part, and holding one"
      (let (root (lock (sample) 300))
        (check (inside-locked? root 4) => #t)
        (check (inside-locked? root 300) => #t)
        (check (inside-locked? root 2) => #f)
        (check (holds-locked? root) => #t)
        (check (holds-locked? (find-part root 200)) => #f)
        (check (holds-locked? (find-part root 300)) => #f)
        (check (link-locked? (part-link root 300)) => #t)
        (check (part-link root 100) => #f)))))
