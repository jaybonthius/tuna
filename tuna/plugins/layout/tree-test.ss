;;; The default layout's tree operations, which are pure: no kernel, no
;;; buffers provider. Views here are bare contract objects.
(import :std/test
        :tuna/services/buffers
        :tuna/plugins/layout/tree)
(export tree-test)

(def fit (make-layout-kind 'fit "" #t #f void))
(def tabbed (make-layout-kind 'tabbed "" #f #t void))
(def (kind-of name) (if (eq? name 'tabbed) tabbed fit))

(def some-buffer (buffer id: 0))

(def (leaf-of id)
  (make-leaf (view id: id showing: some-buffer focus: #f position: 1 revision: 0 goal-column: #f) #f))

(def (ids parts) (map part-id parts))

;; The tree's shape: leaf ids, and (kind direction focus (size shape) ...).
(def (shape p)
  (if (leaf? p)
    (part-id p)
    [(container-kind p) (container-direction p) (container-focus p)
     (map (lambda (l) [(link-size l) (shape (link-part l))]) (container-links p))]))

;; 100 [fit horizontal: 1 | 200 [fit vertical: 2 / 3] | 300 [tabbed: 4, 5]]
(def (sample)
  (make-container 100 'fit 'horizontal
                  [(make-link 1 (leaf-of 1))
                   (make-link 2 (make-container 200 'fit 'vertical
                                                [(make-link 1 (leaf-of 2)) (make-link 1 (leaf-of 3))]
                                                3))
                   (make-link 1 (make-container 300 'tabbed 'horizontal
                                                [(make-link 1 (leaf-of 4)) (make-link 1 (leaf-of 5))]
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
             (inserted (insert-link-after root 300 4 (make-link 1 (leaf-of 8)) kind-of)))
        (check (shape replaced) => ['fit 'horizontal 1 [[1 1] [2 7] [1 ['tabbed 'horizontal 4 [[1 4] [1 5]]]]]])
        (check (ids (part-leaves (find-part inserted 300))) => [4 8 5])))

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
        (check (neighbor-leaf (find-part root 200) 2 'horizontal #f kind-of) => #f)))))
