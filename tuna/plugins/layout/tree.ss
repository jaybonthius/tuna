;;; The default layout's tree (ADR 11, ADR 13): a frozen value of
;;; containers and views, and the pure operations on it. An operation never
;;; changes a tree; it returns a new one that shares every part it did not
;;; change, so an old tree stays a valid snapshot.
;;;
;;; A part is a container or a leaf. A container has a kind (`fit`,
;;; `tabbed`, or one a plugin adds), a direction (`horizontal` or
;;; `vertical`), links to its children in order, and the id of the child
;;; that last had the focus. A link holds a child, its size, and two flags:
;;; pinned (the child shows when the frame zooms past it) and locked (a
;;; plugin owns the child: the user cannot unpin or delete it). Sizes are
;;; weights, or `content` for as big as the child's content. A leaf holds a
;;; view and whether the view is dedicated to its buffer. Every part has a
;;; stable id: a container its own, a leaf its view's.
;;;
;;; Operations that depend on what a kind does take KIND-OF, a procedure
;;; from a kind's name to its `layout-kind`.
prelude: :gerbil/core

(import :tuna/services/buffers)
(export (struct-out container link leaf layout-kind)
        new-link
        link-with-part
        leaf-view
        part-id
        find-part
        part-path
        part-link
        link-index
        parent-container
        part-leaves
        focused-link
        focused-leaf
        child-toward
        visible-leaves
        drawn-part
        select-path
        replace-part
        remove-part
        update-link
        split-part
        insert-link
        move-part
        inside-locked?
        holds-locked?
        neighbor-leaf
        common-ancestor-id)

(defstruct container ((id        : :fixnum)
                      (kind      : :symbol)
                      (direction : :symbol)      ; horizontal or vertical
                      (links     : :list)        ; links to the children, in order
                      (focus     : :fixnum))     ; the id of the child last focused
  final: #t)

;; A child, its size, and its flags on its link to the parent: they travel
;; with the link, so a moved part keeps them unless a command changes
;; them. SIZE is a positive weight or `content`.
(defstruct link ((size    : :t)
                 (part    : :t)
                 (pinned? : :boolean)
                 (locked? : :boolean))
  final: #t)

(def (new-link (size : :t) (part : :t)) => link
  (make-link size part #f #f))

;; L with PART as its child, keeping its size and flags.
(def (link-with-part (l : link) (part : :t)) => link
  (make-link l.size part l.pinned? l.locked?))

(defstruct leaf ((content    : view)         ; a slot cannot be named like its type
                 (dedicated? : :boolean))       ; closes when its buffer goes
  final: #t)

(def (leaf-view (l : leaf)) => view
  (leaf-content l))

;; What a container kind does. SPATIAL? kinds show every child side by
;; side along their direction, so moving to a neighbor crosses them; other
;; kinds show only the focused child. A kind that does not KEEP-ONE-CHILD?
;; is replaced by its child when only one is left. RENDER draws a
;; container of the kind for the `html` target; see the layout plugin.
(defstruct layout-kind ((name            : :symbol)
                           (doc             : :string)
                           (spatial?        : :boolean)
                           (keep-one-child? : :boolean)
                           (render          : :procedure))
  final: #t)

(def (part-id (p : :t)) => :fixnum
  (if (container? p)
    (container-id p)
    (view-id (leaf-view p))))

;; The part of ROOT with id ID, or #f.
(def (find-part (root : :t) (id : :fixnum)) => :t
  (let walk ((p root))
    (cond
     ((fx= (part-id p) id) p)
     ((container? p) (ormap (lambda ((l : link)) (walk l.part)) (container-links p)))
     (else #f))))

;; The parts from ROOT down to the part with id ID, both included, or #f.
(def (part-path (root : :t) (id : :fixnum)) => (Maybe :list)
  (let walk ((p root))
    (cond
     ((fx= (part-id p) id) [p])
     ((container? p)
      (ormap (lambda ((l : link))
               (let (below (walk l.part))
                 (and below (cons p below))))
             (container-links p)))
     (else #f))))

;; The link from C to its child with id ID.
(def (child-link (c : container) (id : :fixnum)) => link
  (let (links (container-links c))
    (list-ref links (link-index links id))))

;; The link to the part with id ID, or #f for ROOT itself.
(def (part-link (root : :t) (id : :fixnum)) => (Maybe link)
  (let (parent (parent-container root id))
    (and parent (child-link parent id))))

;; The container holding the part with id ID, or #f for ROOT itself.
(def (parent-container (root : :t) (id : :fixnum)) => (Maybe container)
  (let (path (part-path root id))
    (and path (pair? (cdr path))
         (list-ref path (fx- (length path) 2)))))

;; Every leaf under P, in order.
(def (part-leaves (p : :t)) => :list
  (reverse
   (let walk ((p p) (out []))
     (if (container? p)
       (foldl (lambda ((l : link) (out : :list)) (walk l.part out)) out (container-links p))
       (cons p out)))))

;; The link to C's focused child, or to its first if the focus is unknown.
(def (focused-link (c : container)) => link
  (let (links (container-links c))
    (or (find (lambda ((l : link)) (fx= (part-id l.part) (container-focus c))) links)
        (car links))))

;; The leaf reached from P by following each container's focus memory.
(def (focused-leaf (p : :t)) => leaf
  (if (container? p)
    (focused-leaf (link-part (focused-link p)))
    p))

;; The child of C on the way to the part with id ID, or #f.
(def (child-toward (c : container) (id : :fixnum)) => :t
  (let (l (find (lambda ((l : link)) (find-part l.part id)) (container-links c)))
    (and l (link-part l))))

;; The leaves under P that show: all children of spatial kinds, only the
;; focused child of the others.
(def (visible-leaves (p : :t) (kind-of : :procedure)) => :list
  (reverse
   (let walk ((p p) (out []))
     (cond
      ((leaf? p) (cons p out))
      ((layout-kind-spatial? (kind-of (container-kind p)))
       (foldl (lambda ((l : link) (out : :list)) (walk l.part out)) out (container-links p)))
      (else (walk (link-part (focused-link p)) out))))))

;; ROOT as drawn with the frame on the part TARGET-ID (ADR 13, pinning):
;; each container on the way from ROOT down to the target keeps only its
;; child on the way and its pinned children, in order, and is focused on
;; the child on the way, which takes the weights of the children left out
;; (the space the pinned children do not use). A container left with only
;; the child on the way is replaced by it, whatever its kind, so without
;; pins this is the target alone. The target and everything under it are
;; drawn as they are.
(def (drawn-part (root : :t) (target-id : :fixnum)) => :t
  (let down ((path (or (part-path root target-id) (error "No part with id" target-id))))
    (match path
      ([p] p)
      ([c . more]
       (using (c : container)
         (let* ((on-way (part-id (car more)))
                (drawn (down more))
                (kept (filter (lambda ((l : link)) (or l.pinned? (fx= (part-id l.part) on-way)))
                              c.links)))
           (if (null? (cdr kept))
             drawn
             (let (weight (foldl (lambda ((l : link) (sum : :real))
                                   (if (and (real? l.size)
                                            (or (fx= (part-id l.part) on-way) (not (memq l kept))))
                                     (+ sum l.size)
                                     sum))
                                 0 c.links))
               (make-container c.id c.kind c.direction
                               (map (lambda ((l : link))
                                      (if (fx= (part-id l.part) on-way)
                                        (make-link (if (> weight 0) weight 1) drawn l.pinned? l.locked?)
                                        l))
                                    kept)
                               on-way)))))))))

;; Index of the link to the child with id ID in LINKS.
(def (link-index (links : :list) (id : :fixnum)) => :fixnum
  (let lp ((rest links) (i 0))
    (match rest
      ([l . more] (if (fx= (part-id (link-part l)) id) i (lp more (fx1+ i))))
      ([] (error "No child with id" id)))))

(def (with-links (c : container) (links : :list) (focus : :fixnum)) => container
  (make-container (container-id c) (container-kind c) (container-direction c) links focus))

;; ROOT with the part at the end of PATH (from ROOT) replaced by NEW, and
;; nothing else changed: no container collapses.
(def (substitute-path (path : :list) (new : :t)) => :t
  (let up ((ancestors (cdr (reverse path))) (old-id (part-id (last path))) (new new))
    (match ancestors
      ([] new)
      ([c . more]
       (up more (container-id c)
           (with-links c (replace-link (container-links c) old-id new) (container-focus c)))))))

;; ROOT with every container on the way to the part with id ID focused
;; toward it (focus memory). Containers already focused that way are shared.
(def (select-path (root : :t) (id : :fixnum)) => :t
  (let (path (or (part-path root id) (error "No part with id" id)))
    (let up ((ancestors (cdr (reverse path))) (old (last path)) (new (last path)))
      (match ancestors
        ([] new)
        ([c . more]
         (up more c
             (if (and (eq? old new) (fx= (container-focus c) (part-id old)))
               c
               (with-links c (replace-link (container-links c) (part-id old) new) (part-id old)))))))))

;; LINKS with the child whose id is ID replaced by NEW, keeping its link.
(def (replace-link (links : :list) (id : :fixnum) (new : :t)) => :list
  (map (lambda ((l : link))
         (if (fx= (part-id l.part) id) (link-with-part l new) l))
       links))

;; C with its child OLD-ID replaced by NEW, or removed when NEW is #f. A
;; removed focused child passes the focus to its previous sibling (or the
;; next). Returns the new container, #f if it has no children left, or its
;; only child if its kind does not keep one.
(def (replace-child (c : container) (old-id : :fixnum) (new : :t) (kind-of : :procedure)) => :t
  (let* ((links (container-links c))
         (index (link-index links old-id))
         (links (if new
                  (replace-link links old-id new)
                  (append (take links index) (drop links (fx1+ index)))))
         (focus (cond
                 ((not (fx= (container-focus c) old-id)) (container-focus c))
                 (new (part-id new))
                 ((null? links) 0)
                 (else (part-id (link-part (list-ref links (fxmax 0 (fx1- index)))))))))
    (cond
     ((null? links) #f)
     ((and (null? (cdr links))
           (not (layout-kind-keep-one-child? (kind-of (container-kind c)))))
      (link-part (car links)))
     (else (with-links c links focus)))))

;; ROOT with the part at the end of PATH (from ROOT) replaced by NEW, or
;; removed when NEW is #f; containers left empty go too, and single
;; children replace their containers as their kinds say. #f when nothing
;; is left.
(def (rebuild-path (path : :list) (new : :t) (kind-of : :procedure)) => :t
  (let up ((ancestors (cdr (reverse path))) (old-id (part-id (last path))) (new new))
    (match ancestors
      ([] new)
      ([c . more] (up more (container-id c) (replace-child c old-id new kind-of))))))

;; ROOT with the part ID replaced by NEW, which takes its link.
(def (replace-part (root : :t) (id : :fixnum) (new : :t) (kind-of : :procedure)) => :t
  (rebuild-path (or (part-path root id) (error "No part with id" id)) new kind-of))

;; ROOT without the part ID, or #f if nothing is left.
(def (remove-part (root : :t) (id : :fixnum) (kind-of : :procedure)) => :t
  (rebuild-path (or (part-path root id) (error "No part with id" id)) #f kind-of))

;; ROOT with the link to the part ID replaced by (CHANGE link), which must
;; keep the part.
(def (update-link (root : :t) (id : :fixnum) (change : :procedure)) => :t
  (let* ((path (or (part-path root id) (error "No part with id" id)))
         (parent (if (pair? (cdr path))
                   (list-ref path (fx- (length path) 2))
                   (error "The whole layout has no link" id))))
    (substitute-path (reverse (cdr (reverse path)))
                     (with-links parent
                                 (map (lambda ((l : link))
                                        (if (fx= (part-id l.part) id) (change l) l))
                                      (container-links parent))
                                 (container-focus parent)))))

;; ROOT with NEW placed after the part ID along DIRECTION, as splitting a
;; view does. Inside a fit container of that direction, the part's link is
;; halved between the two; otherwise the part is replaced by a new fit
;; container with id CONTAINER-ID holding both, focused on the part.
(def (split-part (root : :t) (id : :fixnum) (new : :t) (direction : :symbol)
                 (container-id : :fixnum) (kind-of : :procedure))
  => :t
  (let* ((path (or (part-path root id) (error "No part with id" id)))
         (parent (and (pair? (cdr path)) (list-ref path (fx- (length path) 2)))))
    (if (and parent
             (eq? (container-kind parent) 'fit)
             (eq? (container-direction parent) direction)
             (real? (link-size (child-link parent id))))
      (rebuild-path (reverse (cdr (reverse path)))
                    (with-links parent
                                (let lp ((links (container-links parent)))
                                  (match links
                                    ([l . more]
                                     (using (l : link)
                                       (if (fx= (part-id l.part) id)
                                         (let (half (/ l.size 2))
                                           (cons* (make-link half l.part l.pinned? l.locked?)
                                                  (new-link half new)
                                                  more))
                                         (cons l (lp more)))))
                                    ([] [])))
                                (container-focus parent))
                    kind-of)
      (replace-part root id
                    (make-container container-id 'fit direction
                                    [(new-link 1 (last path)) (new-link 1 new)]
                                    id)
                    kind-of))))

;; ROOT with NEW-LINK in the container PARENT-ID, at WHERE: `first`,
;; `last`, (after . ID) or (before . ID) for a child's id.
(def (insert-link (root : :t) (parent-id : :fixnum) (where : :t) (new-link : link)) => :t
  (let* ((path (or (part-path root parent-id) (error "No part with id" parent-id)))
         (parent (last path)))
    (unless (container? parent)
      (error "No container with id" parent-id))
    (let* ((links (container-links parent))
           (links (match where
                    ('first (cons new-link links))
                    ('last (append links [new-link]))
                    (['after . id]
                     (let (i (fx1+ (link-index links id)))
                       (append (take links i) [new-link] (drop links i))))
                    (['before . id]
                     (let (i (link-index links id))
                       (append (take links i) [new-link] (drop links i)))))))
      (substitute-path path (with-links parent links (container-focus parent))))))

;; P with every container left empty removed and every one left with one
;; child replaced by it as its kind says; a focus on a child that changed
;; follows it, or goes to the first child. #f when nothing is left.
(def (normalize (p : :t) (kind-of : :procedure)) => :t
  (if (leaf? p)
    p
    (let* ((links (container-links p))
           (kept (filter-map (lambda ((l : link))
                               (let (q (normalize l.part kind-of))
                                 (and q (if (eq? q l.part) l (link-with-part l q)))))
                             links)))
      (cond
       ((null? kept) #f)
       ((and (null? (cdr kept))
             (not (layout-kind-keep-one-child? (kind-of (container-kind p)))))
        (link-part (car kept)))
       ((and (fx= (length kept) (length links)) (andmap eq? kept links)) p)
       (else
        (let* ((old-focus (find (lambda ((l : link)) (fx= (part-id l.part) (container-focus p))) links))
               (new-focus (and old-focus
                               (find (lambda ((l : link)) (eq? (link-part l) (link-part old-focus))) kept))))
          (with-links p kept (part-id (link-part (or new-focus (car kept)))))))))))

;; ROOT with the part ID moved one step along AXIS (horizontal or
;; vertical; FORWARD? toward the right or down), keeping its link (size,
;; pin and lock): past its neighbor among its siblings in a container of
;; that direction, or into that neighbor when it is a container; at the
;; edge, or in a container across AXIS, out beside the nearest container
;; of that direction above. The same for every kind. #f when it cannot
;; move.
(def (move-part (root : :t) (id : :fixnum) (axis : :symbol) (forward? : :boolean)
                (kind-of : :procedure))
  => :t
  (let (path (part-path root id))
    (and path (pair? (cdr path))
         (let* ((ancestors (cdr (reverse path)))
                (parent (car ancestors))
                (links (container-links parent))
                (index (link-index links id))
                (moving (list-ref links index))
                (next ((if forward? fx1+ fx1-) index))
                (side (if forward? 'after 'before))
                (destination
                 (if (and (eq? (container-direction parent) axis) (fx< -1 next (length links)))
                   (let (neighbor (link-part (list-ref links next)))
                     (if (container? neighbor)
                       (cons (container-id neighbor) (if forward? 'first 'last))
                       (cons (container-id parent) (cons side (part-id neighbor)))))
                   (let up ((child parent) (above (cdr ancestors)))
                     (match above
                       ([] #f)
                       ([c . more]
                        (if (eq? (container-direction c) axis)
                          (cons (container-id c) (cons side (container-id child)))
                          (up c more))))))))
           (and destination
                (let (detached (substitute-path (reverse ancestors)
                                                (with-links parent
                                                            (remq moving links)
                                                            (container-focus parent))))
                  (normalize (insert-link detached (car destination) (cdr destination) moving)
                             kind-of)))))))

;; Whether the link to the part ID, or one above it, is locked.
(def (inside-locked? (root : :t) (id : :fixnum)) => :boolean
  (let lp ((path (or (part-path root id) (error "No part with id" id))))
    (match path
      ([c child . more]
       (or (link-locked? (child-link c (part-id child)))
           (lp (cdr path))))
      (else #f))))

;; Whether a link below P is locked.
(def (holds-locked? (p : :t)) => :boolean
  (and (container? p)
       (ormap (lambda ((l : link)) (or l.locked? (holds-locked? l.part)))
              (container-links p))))

;; The leaf a move from the part ID in direction AXIS (horizontal or
;; vertical; FORWARD? for right and down) reaches inside TOP: the nearest
;; spatial container of that direction with a sibling on that side, entered
;; through its focus memory. #f when there is none.
(def (neighbor-leaf (top : :t) (id : :fixnum) (axis : :symbol) (forward? : :boolean)
                    (kind-of : :procedure))
  => (Maybe leaf)
  (let (path (part-path top id))
    (and path
         (let up ((ancestors (cdr (reverse path))) (child-id id))
           (match ancestors
             ([] #f)
             ([c . more]
              (let* ((links (container-links c))
                     (next ((if forward? fx1+ fx1-) (link-index links child-id))))
                (if (and (layout-kind-spatial? (kind-of (container-kind c)))
                         (eq? (container-direction c) axis)
                         (fx< -1 next (length links)))
                  (focused-leaf (link-part (list-ref links next)))
                  (up more (container-id c))))))))))

;; The id of the lowest part of ROOT holding every part in IDS (all of
;; ROOT's), or #f if one of them is not in ROOT.
(def (common-ancestor-id (root : :t) (ids : :list)) => (Maybe :fixnum)
  (let (paths (map (cut part-path root <>) ids))
    (and (pair? paths)
         (andmap identity paths)
         (let lp ((paths paths) (lowest root))
           (if (and (andmap pair? paths)
                    (let (first (car (car paths)))
                      (andmap (lambda ((path : :pair)) (eq? (car path) first)) paths)))
             (lp (map cdr paths) (car (car paths)))
             (part-id lowest))))))
