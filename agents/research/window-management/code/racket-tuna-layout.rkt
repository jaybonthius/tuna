#lang racket/base

(require racket/list)

(provide
  (struct-out layout-tree)
  (struct-out layout-node)
  (struct-out layout-child)
  (struct-out layout-leaf)
  (struct-out frame)
  (struct-out session)
  layout-direction?
  layout-tiling?
  layout-measure?
  layout-item-id
  validate-layout-tree
  layout-find-node
  layout-find-leaf
  layout-find-parent
  layout-first-leaf-id
  layout-descendant?
  layout-preorder
  layout-align-scroll-anchors
  layout-insert-leaf
  layout-set-leaf-view
  layout-wrap-item
  layout-move-child
  layout-remove-leaf
  layout-unwrap-node
  layout-set-node-direction
  layout-set-node-tiling
  layout-set-child-measure)

(struct layout-tree (id root) #:transparent)
(struct layout-node (id direction tiling scroll-anchor-id children) #:transparent)
(struct layout-child (measure child) #:transparent)
(struct layout-leaf (id view-id) #:transparent)
(struct frame (id layout-tree-id layout-node-id active-leaf-id) #:transparent)
(struct session (id layout-trees frames active-frame-id) #:transparent)
(struct parent-location (parent child))

(define (positive-id? value)
  (and (exact-integer? value) (positive? value)))

(define (layout-direction? value)
  (or (eq? value 'horizontal) (eq? value 'vertical)))

(define (layout-tiling? value)
  (or (eq? value 'fit) (eq? value 'scroll)))

(define (layout-measure? value)
  (and (real? value)
       (<= 0 value)
       (<= value 1)))

(define (layout-item-id item)
  (cond
    [(layout-node? item) (layout-node-id item)]
    [(layout-leaf? item) (layout-leaf-id item)]
    [else (raise-argument-error 'layout-item-id
                                "(or/c layout-node? layout-leaf?)"
                                item)]))

(define (raise-invalid who message value)
  (raise-arguments-error who message "value" value))

(define (validate-layout-tree tree)
  (unless (layout-tree? tree)
    (raise-argument-error 'validate-layout-tree "layout-tree?" tree))
  (unless (positive-id? (layout-tree-id tree))
    (raise-invalid 'validate-layout-tree
                   "layout tree ID must be a positive exact integer"
                   (layout-tree-id tree)))
  (unless (layout-node? (layout-tree-root tree))
    (raise-invalid 'validate-layout-tree
                   "layout tree root must be a layout node"
                   (layout-tree-root tree)))
  (define seen-ids (make-hash))
  (define visiting (make-hasheq))
  (define (walk item)
    (unless (or (layout-node? item) (layout-leaf? item))
      (raise-invalid 'validate-layout-tree
                     "layout child must be a layout node or leaf"
                     item))
    (when (hash-ref visiting item #f)
      (raise-invalid 'validate-layout-tree "layout tree must be acyclic" item))
    (define id (layout-item-id item))
    (unless (positive-id? id)
      (raise-invalid 'validate-layout-tree
                     "layout item ID must be a positive exact integer"
                     id))
    (when (and (layout-leaf? item)
               (not (positive-id? (layout-leaf-view-id item))))
      (raise-invalid 'validate-layout-tree
                     "layout leaf view ID must be a positive exact integer"
                     (layout-leaf-view-id item)))
    (when (hash-has-key? seen-ids id)
      (raise-invalid 'validate-layout-tree
                     "layout item IDs must be globally unique"
                     id))
    (hash-set! seen-ids id #t)
    (when (layout-node? item)
      (unless (layout-direction? (layout-node-direction item))
        (raise-invalid 'validate-layout-tree
                       "layout node direction must be horizontal or vertical"
                       (layout-node-direction item)))
      (unless (layout-tiling? (layout-node-tiling item))
        (raise-invalid 'validate-layout-tree
                       "layout node tiling must be fit or scroll"
                       (layout-node-tiling item)))
      (define children (layout-node-children item))
      (unless (and (list? children) (pair? children))
        (raise-invalid 'validate-layout-tree
                       "layout node children must be a nonempty list"
                       children))
      (for ([child (in-list children)])
        (unless (layout-child? child)
          (raise-invalid 'validate-layout-tree
                         "layout node child must be a layout-child"
                         child))
        (unless (layout-measure? (layout-child-measure child))
          (raise-invalid 'validate-layout-tree
                         "layout child measure must be a finite real from 0 through 1"
                         (layout-child-measure child))))
      (define scroll-anchor-id (layout-node-scroll-anchor-id item))
      (if (eq? (layout-node-tiling item) 'fit)
          (when scroll-anchor-id
            (raise-invalid 'validate-layout-tree
                           "fit layout node scroll anchor must be #f"
                           scroll-anchor-id))
          (unless (and (positive-id? scroll-anchor-id)
                       (for/or ([child (in-list children)])
                         (= (layout-item-id (layout-child-child child))
                            scroll-anchor-id)))
            (raise-invalid 'validate-layout-tree
                           "scroll layout node anchor must identify a direct child"
                           scroll-anchor-id)))
      (hash-set! visiting item #t)
      (for ([child (in-list children)])
        (walk (layout-child-child child)))
      (hash-remove! visiting item)))
  (walk (layout-tree-root tree))
  tree)

(define (layout-preorder tree)
  (validate-layout-tree tree)
  (define (walk item)
    (if (layout-node? item)
        (cons item
              (append-map (lambda (child)
                            (walk (layout-child-child child)))
                          (layout-node-children item)))
        (list item)))
  (walk (layout-tree-root tree)))

(define (layout-find-node tree target-id)
  (for/or ([item (in-list (layout-preorder tree))])
    (and (layout-node? item)
         (= (layout-node-id item) target-id)
         item)))

(define (layout-find-leaf tree target-id)
  (for/or ([item (in-list (layout-preorder tree))])
    (and (layout-leaf? item)
         (= (layout-leaf-id item) target-id)
         item)))

(define (find-parent-location tree target-id)
  (define (walk node)
    (for/or ([child (in-list (layout-node-children node))])
      (define item (layout-child-child child))
      (cond
        [(= (layout-item-id item) target-id) (parent-location node child)]
        [(layout-node? item) (walk item)]
        [else #f])))
  (walk (layout-tree-root tree)))

(define (layout-find-parent tree target-id)
  (validate-layout-tree tree)
  (define location (find-parent-location tree target-id))
  (and location (parent-location-parent location)))

(define (layout-first-leaf-id tree [node-id #f])
  (validate-layout-tree tree)
  (define root
    (if node-id
        (layout-find-node tree node-id)
        (layout-tree-root tree)))
  (define (walk item)
    (cond
      [(layout-leaf? item) (layout-leaf-id item)]
      [else
       (for/or ([child (in-list (layout-node-children item))])
         (walk (layout-child-child child)))]))
  (and root (walk root)))

(define (layout-descendant? tree ancestor-node-id item-id)
  (define ancestor (layout-find-node tree ancestor-node-id))
  (define (walk item)
    (or (= (layout-item-id item) item-id)
        (and (layout-node? item)
             (for/or ([child (in-list (layout-node-children item))])
               (walk (layout-child-child child))))))
  (and ancestor (walk ancestor)))

(define (layout-align-scroll-anchors tree ancestor-node-id leaf-id)
  (validate-layout-tree tree)
  (define ancestor
    (or (layout-find-node tree ancestor-node-id)
        (raise-arguments-error 'layout-align-scroll-anchors
                               "layout node not found"
                               "id"
                               ancestor-node-id)))
  (unless (and (layout-find-leaf tree leaf-id)
               (layout-descendant? tree ancestor-node-id leaf-id))
    (raise-arguments-error 'layout-align-scroll-anchors
                           "leaf must descend from the layout node"
                           "leaf-id"
                           leaf-id))
  (define (contains-leaf? item)
    (or (and (layout-leaf? item) (= (layout-leaf-id item) leaf-id))
        (and (layout-node? item)
             (for/or ([child (in-list (layout-node-children item))])
               (contains-leaf? (layout-child-child child))))))
  (define (align node)
    (define path-child
      (for/first ([child (in-list (layout-node-children node))]
                  #:when (contains-leaf? (layout-child-child child)))
        child))
    (layout-node
      (layout-node-id node)
      (layout-node-direction node)
      (layout-node-tiling node)
      (and (eq? (layout-node-tiling node) 'scroll)
           (layout-item-id (layout-child-child path-child)))
      (for/list ([child (in-list (layout-node-children node))])
        (define item (layout-child-child child))
        (layout-child (layout-child-measure child)
                      (if (and (eq? child path-child) (layout-node? item))
                          (align item)
                          item)))))
  (finish-tree
    (replace-item tree (layout-node-id ancestor) (align ancestor))))

(define (require-layout-tree _who tree)
  (validate-layout-tree tree)
  tree)

(define (require-node who tree node-id)
  (or (layout-find-node tree node-id)
      (raise-arguments-error who "layout node not found" "id" node-id)))

(define (require-leaf who tree leaf-id)
  (or (layout-find-leaf tree leaf-id)
      (raise-arguments-error who "layout leaf not found" "id" leaf-id)))

(define (require-fresh-item-id who tree item-id)
  (unless (positive-id? item-id)
    (raise-argument-error who "positive-exact-integer?" item-id))
  (when (for/or ([item (in-list (layout-preorder tree))])
          (= (layout-item-id item) item-id))
    (raise-arguments-error who "layout item ID is already allocated" "id" item-id)))

(define (require-index who index child-count)
  (cond
    [(not index) child-count]
    [(and (exact-nonnegative-integer? index) (<= index child-count)) index]
    [else
     (raise-arguments-error who
                            "index must be #f or a valid zero-based child position"
                            "index"
                            index)]))

(define (insert-at items index item)
  (append (take items index) (list item) (drop items index)))

(define (replace-item tree target-id replacement)
  (define (walk item)
    (cond
      [(= (layout-item-id item) target-id) replacement]
      [(layout-node? item)
       (layout-node (layout-node-id item)
                    (layout-node-direction item)
                    (layout-node-tiling item)
                    (layout-node-scroll-anchor-id item)
                    (for/list ([child (in-list (layout-node-children item))])
                      (layout-child (layout-child-measure child)
                                    (walk (layout-child-child child)))))]
      [else item]))
  (layout-tree (layout-tree-id tree) (walk (layout-tree-root tree))))

(define (replace-node tree node-id transform)
  (define old-node (require-node 'replace-node tree node-id))
  (replace-item tree node-id (transform old-node)))

(define (find-node-unchecked tree target-id)
  (define (walk item)
    (cond
      [(and (layout-node? item) (= (layout-node-id item) target-id)) item]
      [(layout-node? item)
       (for/or ([child (in-list (layout-node-children item))])
         (walk (layout-child-child child)))]
      [else #f]))
  (walk (layout-tree-root tree)))

(define (replace-node-unchecked tree node-id transform)
  (define (walk item)
    (cond
      [(and (layout-node? item) (= (layout-node-id item) node-id))
       (transform item)]
      [(layout-node? item)
       (layout-node (layout-node-id item)
                    (layout-node-direction item)
                    (layout-node-tiling item)
                    (layout-node-scroll-anchor-id item)
                    (for/list ([child (in-list (layout-node-children item))])
                      (layout-child (layout-child-measure child)
                                    (walk (layout-child-child child)))))]
      [else item]))
  (layout-tree (layout-tree-id tree) (walk (layout-tree-root tree))))

(define (remove-item-and-prune who tree item-id
                               #:preserve-node-id [preserve-node-id #f])
  (define (walk node)
    (define children
      (reverse
        (for/fold ([result '()]) ([child (in-list (layout-node-children node))])
          (define item (layout-child-child child))
          (cond
            [(= (layout-item-id item) item-id) result]
            [(layout-node? item)
             (define replacement (walk item))
             (if replacement
                 (cons (layout-child (layout-child-measure child) replacement) result)
                 result)]
            [else (cons child result)]))))
    (cond
      [(pair? children)
       (layout-node (layout-node-id node)
                    (layout-node-direction node)
                    (layout-node-tiling node)
                    (layout-node-scroll-anchor-id node)
                    children)]
      [(and preserve-node-id (= (layout-node-id node) preserve-node-id))
       (layout-node (layout-node-id node)
                    (layout-node-direction node)
                    (layout-node-tiling node)
                    (layout-node-scroll-anchor-id node)
                    children)]
      [else #f]))
  (define root (walk (layout-tree-root tree)))
  (unless root
    (raise-arguments-error who
                           "pruning cannot delete the layout tree root"
                           "id"
                           item-id))
  (layout-tree (layout-tree-id tree) root))

(define (repair-scroll-anchors tree)
  (define (walk item)
    (cond
      [(layout-leaf? item) item]
      [else
       (define children
         (for/list ([child (in-list (layout-node-children item))])
           (layout-child (layout-child-measure child)
                         (walk (layout-child-child child)))))
       (define anchor-id (layout-node-scroll-anchor-id item))
       (layout-node
         (layout-node-id item)
         (layout-node-direction item)
         (layout-node-tiling item)
         (and (eq? (layout-node-tiling item) 'scroll)
              (if (for/or ([child (in-list children)])
                    (and (exact-integer? anchor-id)
                         (= (layout-item-id (layout-child-child child)) anchor-id)))
                  anchor-id
                  (layout-item-id (layout-child-child (car children)))))
         children)]))
  (layout-tree (layout-tree-id tree) (walk (layout-tree-root tree))))

(define (finish-tree tree)
  (define repaired (repair-scroll-anchors tree))
  (validate-layout-tree repaired)
  repaired)

(define (layout-insert-leaf tree parent-node-id leaf-id view-id
                            #:at [index #f]
                            #:measure [measure 1])
  (require-layout-tree 'layout-insert-leaf tree)
  (require-node 'layout-insert-leaf tree parent-node-id)
  (require-fresh-item-id 'layout-insert-leaf tree leaf-id)
  (unless (positive-id? view-id)
    (raise-argument-error 'layout-insert-leaf "positive-exact-integer?" view-id))
  (unless (layout-measure? measure)
    (raise-argument-error 'layout-insert-leaf "layout-measure?" measure))
  (define parent (layout-find-node tree parent-node-id))
  (define insertion-index
    (require-index 'layout-insert-leaf index (length (layout-node-children parent))))
  (finish-tree
    (replace-node
      tree
      parent-node-id
      (lambda (node)
        (layout-node (layout-node-id node)
                     (layout-node-direction node)
                     (layout-node-tiling node)
                     (layout-node-scroll-anchor-id node)
                     (insert-at (layout-node-children node)
                                insertion-index
                                (layout-child measure (layout-leaf leaf-id view-id))))))))

(define (layout-set-leaf-view tree leaf-id view-id)
  (require-layout-tree 'layout-set-leaf-view tree)
  (require-leaf 'layout-set-leaf-view tree leaf-id)
  (unless (positive-id? view-id)
    (raise-argument-error 'layout-set-leaf-view "positive-exact-integer?" view-id))
  (finish-tree
    (replace-item tree leaf-id (layout-leaf leaf-id view-id))))

(define (layout-wrap-item tree item-id node-id direction
                          #:tiling [tiling 'fit]
                          #:measure [inner-measure 1])
  (require-layout-tree 'layout-wrap-item tree)
  (unless (or (layout-find-node tree item-id) (layout-find-leaf tree item-id))
    (raise-arguments-error 'layout-wrap-item "layout item not found" "id" item-id))
  (require-fresh-item-id 'layout-wrap-item tree node-id)
  (unless (layout-direction? direction)
    (raise-argument-error 'layout-wrap-item "layout-direction?" direction))
  (unless (layout-tiling? tiling)
    (raise-argument-error 'layout-wrap-item "layout-tiling?" tiling))
  (unless (layout-measure? inner-measure)
    (raise-argument-error 'layout-wrap-item "layout-measure?" inner-measure))
  (define item
    (or (layout-find-node tree item-id) (layout-find-leaf tree item-id)))
  (finish-tree
    (replace-item tree
                  item-id
                  (layout-node node-id
                               direction
                               tiling
                               (and (eq? tiling 'scroll) item-id)
                               (list (layout-child inner-measure item))))))

(define (layout-move-child tree child-id destination-node-id
                           #:at [index #f]
                           #:measure [measure #f])
  (require-layout-tree 'layout-move-child tree)
  (define source-item
    (or (layout-find-node tree child-id) (layout-find-leaf tree child-id)
        (raise-arguments-error 'layout-move-child "layout item not found" "id" child-id)))
  (when (= child-id (layout-node-id (layout-tree-root tree)))
    (raise-arguments-error 'layout-move-child "the tree root cannot move" "id" child-id))
  (define source-location (find-parent-location tree child-id))
  (define source-parent (parent-location-parent source-location))
  (define source-child (parent-location-child source-location))
  (require-node 'layout-move-child tree destination-node-id)
  (when (and (layout-node? source-item)
             (layout-descendant? tree child-id destination-node-id))
    (raise-arguments-error 'layout-move-child
                           "a node cannot move beneath itself or a descendant"
                           "destination-node-id"
                           destination-node-id))
  (unless (or (not measure) (layout-measure? measure))
    (raise-argument-error 'layout-move-child "(or/c layout-measure? #f)" measure))
  (define replacement-measure (or measure (layout-child-measure source-child)))
  (cond
    [(= (layout-node-id source-parent) destination-node-id)
     (define children
       (filter (lambda (child)
                 (not (= (layout-item-id (layout-child-child child)) child-id)))
               (layout-node-children source-parent)))
     (define insertion-index
       (require-index 'layout-move-child index (length children)))
     (finish-tree
       (replace-node
         tree
         (layout-node-id source-parent)
         (lambda (node)
           (layout-node (layout-node-id node)
                        (layout-node-direction node)
                        (layout-node-tiling node)
                        (layout-node-scroll-anchor-id node)
                        (insert-at children
                                   insertion-index
                                   (layout-child replacement-measure source-item))))))]
    [else
     (define detached
       (remove-item-and-prune 'layout-move-child
                              tree
                              child-id
                              #:preserve-node-id destination-node-id))
     (define detached-destination
       (find-node-unchecked detached destination-node-id))
     (define insertion-index
       (require-index 'layout-move-child
                      index
                      (length (layout-node-children detached-destination))))
     (finish-tree
       (replace-node-unchecked
         detached
         destination-node-id
         (lambda (node)
           (layout-node (layout-node-id node)
                        (layout-node-direction node)
                        (layout-node-tiling node)
                        (layout-node-scroll-anchor-id node)
                        (insert-at (layout-node-children node)
                                   insertion-index
                                   (layout-child replacement-measure source-item))))))]))

(define (layout-remove-leaf tree leaf-id)
  (require-layout-tree 'layout-remove-leaf tree)
  (require-leaf 'layout-remove-leaf tree leaf-id)
  (finish-tree
    (remove-item-and-prune 'layout-remove-leaf tree leaf-id)))

(define (layout-unwrap-node tree node-id)
  (require-layout-tree 'layout-unwrap-node tree)
  (define node (require-node 'layout-unwrap-node tree node-id))
  (unless (= (length (layout-node-children node)) 1)
    (raise-arguments-error 'layout-unwrap-node
                           "layout node must have exactly one child"
                           "id"
                           node-id))
  (define child (layout-child-child (car (layout-node-children node))))
  (cond
    [(= node-id (layout-node-id (layout-tree-root tree)))
     (unless (layout-node? child)
       (raise-arguments-error 'layout-unwrap-node
                              "a root can be unwrapped only to a layout node"
                              "id"
                              node-id))
     (finish-tree (layout-tree (layout-tree-id tree) child))]
    [else (finish-tree (replace-item tree node-id child))]))

(define (layout-set-node-direction tree node-id direction)
  (require-layout-tree 'layout-set-node-direction tree)
  (unless (layout-direction? direction)
    (raise-argument-error 'layout-set-node-direction "layout-direction?" direction))
  (finish-tree
    (replace-node
      tree
      node-id
      (lambda (node)
        (layout-node (layout-node-id node)
                     direction
                     (layout-node-tiling node)
                     (layout-node-scroll-anchor-id node)
                     (layout-node-children node))))))

(define (layout-set-node-tiling tree node-id tiling)
  (require-layout-tree 'layout-set-node-tiling tree)
  (unless (layout-tiling? tiling)
    (raise-argument-error 'layout-set-node-tiling "layout-tiling?" tiling))
  (finish-tree
    (replace-node
      tree
      node-id
      (lambda (node)
        (layout-node
          (layout-node-id node)
          (layout-node-direction node)
          tiling
          (cond
            [(eq? tiling 'fit) #f]
            [(eq? (layout-node-tiling node) 'scroll)
             (layout-node-scroll-anchor-id node)]
            [else
             (layout-item-id
               (layout-child-child (car (layout-node-children node))))])
          (layout-node-children node))))))

(define (layout-set-child-measure tree parent-node-id child-id measure)
  (require-layout-tree 'layout-set-child-measure tree)
  (require-node 'layout-set-child-measure tree parent-node-id)
  (unless (layout-measure? measure)
    (raise-argument-error 'layout-set-child-measure "layout-measure?" measure))
  (define parent (layout-find-node tree parent-node-id))
  (unless (for/or ([child (in-list (layout-node-children parent))])
            (= (layout-item-id (layout-child-child child)) child-id))
    (raise-arguments-error 'layout-set-child-measure
                           "layout item is not a direct child of the parent"
                           "child-id"
                           child-id))
  (finish-tree
    (replace-node
      tree
      parent-node-id
      (lambda (node)
        (layout-node
          (layout-node-id node)
          (layout-node-direction node)
          (layout-node-tiling node)
          (layout-node-scroll-anchor-id node)
          (for/list ([child (in-list (layout-node-children node))])
            (if (= (layout-item-id (layout-child-child child)) child-id)
                (layout-child measure (layout-child-child child))
                child)))))))

