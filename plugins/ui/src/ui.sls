#!tuna
(import (buffers) (document) (views) (keys) (commands) (modes) (web) (haml) (hooks) (options) (tables))

;; This module defines list as a kind constructor, so its own code builds
;; lists with cons and quasiquote.

(tables:define-table %buttons)

(tables:define-table list-keys "Keys that move through a list and choose its row.")

(tables:define-table list-click-keys "Clicks on a list whose click chooses: off a row, they run nothing.")

(tables:define-table row-keys "Clicks on a row of a list whose click chooses: a click chooses the row.")

(tables:define-table disabled-keys "Keys that do nothing on a disabled button or link.")

(module %internals
  (draw-labelled button-at disabled? list-node? row-atom? list-state set-list-state! rows-count rows-count-set! rows-draw
   rows-choose rows-generation rows-failed? rows-failed?-set! failure? heading-of row-count selected-index index-position
   row-datum list-at chooses? drawing-rows drawing-selected drawing-start drawing-row-mark drawing-last drawing-last-set!
   drawing-last-heading drawing-last-heading-set! current-drawing with-drawing place clicked-posn posn-or-point
   forget-buffer!)

  (define (disabled? node) (and (document:node-attribute node 'disabled #f) #t))

  ;; Not the disabled attribute, with which the browser drops the press
  ;; and release of the mouse on the button, so a drag that ends there
  ;; would end only at the next move.
  (define (draw-labelled class node view)
    (haml (:button ([class class] [type "button"] [tabindex "-1"] [aria-disabled (and (disabled? node) "true")])
            (views:draw-children view node))))

  (define (button-at v p)
    (let ([b (views:buffer v)])
      (and b
           (let ([doc (buffers:document b)])
             (and (fx<= p (document:length doc))
                  (let loop ([n (document:enclosing doc p)])
                    (cond
                      [(not n) #f]
                      [(tables:ref %buttons (document:node-kind n) #f) n]
                      [else (loop (document:enclosing doc (document:node-start n)))])))))))

  (define (list-node? n)
    (and n (not (document:atom? n)) (eq? (document:node-kind n) %list-kind)))

  (define (row-atom? t)
    (and (document:node? t) (document:atom? t) (eq? (document:node-kind t) %row-kind)))

  ;; The rows of one call to set-rows! carry one generation, so they
  ;; differ from every earlier call's at the first row, and a click on a
  ;; screen drawn before them is stale rather than choosing whatever row
  ;; took its index. A list whose draw, heading or choose procedure raised
  ;; stays failed until its rows are set again, so a procedure whose
  ;; module is gone is not called, and its error not reported, on every
  ;; draw.
  (define-record-type rows
    (sealed #t)
    (fields (mutable count) (mutable draw) (mutable heading) (mutable choose) (mutable generation) (mutable failed?)))

  ;; Only an anchor right after a node's opening reports the node's deletion.
  (define lists (make-eq-hashtable))

  (define (entries-of b)
    (let ([live (filter (lambda (e) (not (buffers:anchor-deleted? (car e)))) (eq-hashtable-ref lists b '()))])
      (eq-hashtable-set! lists b live)
      live))

  (define (list-state b node)
    (let ([at (fx+ (document:node-start node) 1)])
      (let loop ([es (entries-of b)])
        (cond
          [(null? es) #f]
          [(fx= (buffers:anchor-position (caar es)) at) (cdar es)]
          [else (loop (cdr es))]))))

  (define (first-generation doc node)
    (and (fx> (row-count node) 0)
         (let ([t (document:token doc (fx+ (document:node-start node) 1))])
           (and (row-atom? t)
                (let ([g (document:node-attribute t 'generation)])
                  (and (fixnum? g) g))))))

  ;; A list met afresh, as after this module reloads, may hold rows a
  ;; previous instance wrote, so its first generation is past theirs.
  (define (set-list-state! b node count draw heading choose)
    (let ([state (list-state b node)])
      (if state
          (begin
            (rows-count-set! state count)
            (rows-draw-set! state draw)
            (rows-heading-set! state heading)
            (rows-choose-set! state choose)
            (rows-generation-set! state (fx+ (rows-generation state) 1))
            (rows-failed?-set! state #f)
            state)
          (let* ([g (first-generation (buffers:document b) node)]
                 [state (make-rows count draw heading choose (if g (fx+ g 1) 0) #f)])
            (eq-hashtable-set! lists b
              (cons (cons (buffers:anchor b (fx+ (document:node-start node) 1)) state) (entries-of b)))
            state))))

  (define (forget-buffer! b) (eq-hashtable-delete! lists b))

  (define (row-datum generation) (%list-row `((generation . ,generation))))

  (define (row-count node) (fx- (fx- (document:node-end node) (document:node-start node)) 2))

  (define (row-index node p) (fx- p (fx+ (document:node-start node) 1)))

  (define (index-position node i) (fx+ (document:node-start node) 1 i))

  ;; The row at a point after the last row is the last row, so a list
  ;; whose rows shrink keeps a row selected.
  (define (selected-index node p)
    (let ([n (row-count node)])
      (and (fx> n 0) (fx< (document:node-start node) p (document:node-end node))
           (fxmin (row-index node p) (fx- n 1)))))

  (define (warning-only? c)
    (and (warning? c) (not (serious-condition? c))))

  (define (failure? c)
    (not (or (cancelled? c) (warning-only? c))))

  (define (heading-of state i)
    (and (not (rows-failed? state))
         (guard (c [(failure? c) (rows-failed?-set! state #t) (report c) #f])
           (let ([h ((rows-heading state) i)])
             (unless (or (not h) (string? h))
               (assertion-violation 'ui:set-rows! "a heading procedure returned neither a string nor #f" h))
             h))))

  (define (chooses? node) (not (eq? (document:node-attribute node 'click #f) 'select)))

  (define (list-at v p)
    (let ([b (views:buffer v)])
      (and b
           (let ([doc (buffers:document b)])
             (let loop ([n (document:enclosing doc p)])
               (cond
                 [(not n) #f]
                 [(list-node? n) n]
                 [else (loop (document:enclosing doc (document:node-start n)))]))))))

  ;; The last row drawn and its heading, so that a row's heading is
  ;; compared with the row before's without calling the heading procedure
  ;; for that row again.
  (define-record-type drawing
    (sealed #t)
    (fields rows selected start row-mark (mutable last) (mutable last-heading)))

  (define current-drawing (make-thread-parameter #f))

  (define (with-drawing node view thunk)
    (let ([b (views:buffer view)])
      (parameterize ([current-drawing (make-drawing (list-state b node) (selected-index node (views:point view))
                                                    (document:node-start node)
                                                    (and (chooses? node) (views:keymap-mark row-keys)) #f #f)])
        (thunk))))

  (define (place posn)
    (if posn
        (values (views:posn-view posn) (views:posn-point posn))
        (let ([v (views:current)]) (values v (and v (views:buffer v) (views:point v))))))

  (define (clicked-posn)
    (let ([e (keys:command-event)])
      (and (keys:event? e) (keys:event-start e))))

  (define (posn-or-point) (place (clicked-posn))))

(import %internals)

(define (%draw-button node view) (draw-labelled "ui-button" node view))

(define (%draw-link node view) (draw-labelled "ui-link" node view))

(define (%bind-button! who keymap kind command)
  (unless (commands:command? command)
    (assertion-violation who "not a command" command))
  (keys:bind! keymap "<mouse-1>" command)
  (keys:bind! keymap "<mouse-2>" command)
  (keys:bind! keymap "RET" command)
  (keys:bind! keymap "<down-mouse-1>" keys:ignore)
  (keys:bind! keymap "<drag-mouse-1>" keys:ignore)
  (keys:bind! keymap "<drag-mouse-2>" keys:ignore)
  (tables:set! %buttons kind))

(define-syntax %define-labelled-kind
  (lambda (x)
    (syntax-case x ()
      [(_ who id command-expr drawer)
       (with-syntax ([id-keys (datum->syntax #'id (string->symbol (string-append (symbol->string (syntax->datum #'id)) "-keys")))])
         #'(begin
             (tables:define-table id-keys "The keys of a button kind.")
             (buffers:define-kind id (inline) (draw drawer) (keymap id-keys))
             (define-values () (begin (%bind-button! 'who id-keys (buffers:kind-name (buffers:constructor-kind id)) command-expr) (values)))))])))

(define-syntax define-button
  (lambda (x)
    (syntax-case x ()
      [(_ id command-expr)
       (identifier? #'id)
       #'(%define-labelled-kind ui:define-button id command-expr %draw-button)]
      [_ (syntax-violation 'ui:define-button "expected (ui:define-button id command)" x)])))

(define-syntax define-link
  (lambda (x)
    (syntax-case x ()
      [(_ id command-expr)
       (identifier? #'id)
       #'(%define-labelled-kind ui:define-link id command-expr %draw-link)]
      [_ (syntax-violation 'ui:define-link "expected (ui:define-link id command)" x)])))

(define (pushed-button)
  (let-values ([(v p) (posn-or-point)])
    (or (and v p (button-at v p))
        (assertion-violation 'ui:pushed-button "no button is at the click or at point"))))

;; A list whose click selects leaves every click to the keymaps around it,
;; so the global map's press selects the view and moves point to the row.
(define (%choosing-keymaps client posn)
  (if posn
      (let-values ([(v p) (place posn)])
        (let ([node (and v p (list-at v p))])
          (cond
            [(not (and node (chooses? node))) '()]
            [(row-atom? (views:posn-node posn)) `(,row-keys ,list-click-keys)]
            [else `(,list-click-keys)])))
      '()))

(define (%disabled-keymaps client posn)
  (let-values ([(v p) (place posn)])
    (let ([button (and v p (button-at v p))])
      (if (and button (disabled? button)) (cons disabled-keys '()) '()))))

(define label
  (case-lambda
    [(text) (label text "")]
    [(text class)
     (unless (string? text)
       (assertion-violation 'ui:label "not a string" text))
     (unless (string? class)
       (assertion-violation 'ui:label "not a string" class))
     (haml (:span.ui-label ([class (and (not (string=? class "")) class)]) text))]))

(define (row . items)
  (for-each (lambda (item) (unless (html? item) (assertion-violation 'ui:row "not HTML" item))) items)
  (haml (:div.ui-row items)))

;; A heading goes beside its row's element, not inside it: that element
;; carries the row's position, so a click on the heading would choose the
;; row, the cursor's outline would surround the heading too, and a sticky
;; heading could not outlast its own row. The first row drawn gets its
;; heading whatever the row before it, so a run that starts inside a
;; group still names it.
(define (%with-heading child html)
  (let* ([d (current-drawing)] [state (and d (drawing-rows d))])
    (if (and state (row-atom? child) (not (rows-failed? state)))
        (let* ([i (fx- (document:node-start child) (drawing-start d) 1)] [h (heading-of state i)]
               [shown? (and h (not (and (eqv? (drawing-last d) (fx- i 1))
                                        (drawing-last-heading d) (string=? (drawing-last-heading d) h))))])
          (drawing-last-set! d i)
          (drawing-last-heading-set! d h)
          (if (and shown? (not (rows-failed? state)))
              `(,(haml (:li.ui-list-heading (:span h))) ,html)
              html))
        html)))

;; Rows drawn before one that raised are drawn again, as nothing, so the
;; list is drawn empty from the draw that failed.
(define (%draw-list node view)
  (define (draw)
    (with-drawing node view
      (lambda ()
        (haml (:ul.ui-list ([data-keymap (and (chooses? node) (views:keymap-mark list-click-keys))])
                (views:draw-children view node %with-heading))))))
  (let* ([state (list-state (views:buffer view) node)] [failed? (and state (rows-failed? state))] [html (draw)])
    (if (and state (not failed?) (rows-failed? state)) (draw) html)))

(define (%draw-list-row node view)
  (let* ([d (current-drawing)] [state (and d (drawing-rows d))]
         [i (and d (fx- (document:node-start node) (drawing-start d) 1))])
    (if (and state (not (rows-failed? state)) (fx< i (rows-count state)))
        (guard (c [(failure? c) (rows-failed?-set! state #t) (report c) '()])
          (haml (:li.ui-list-row ([aria-current (and (eqv? i (drawing-selected d)) "true")] [data-keymap (drawing-row-mark d)])
                  ((rows-draw state) i))))
        '())))

;; Rows go only when ui writes them, which asks no kind. Text, which the
;; list's content refuses anyway, is consented to: refusing it would also
;; refuse the probe that makes the place before a row a stop, and point
;; could not rest on the first row of a list inside other text.
(define (%keep-rows node edit)
  (and (fx= (buffers:piece-length (buffers:edit-removed edit)) 0)
       (let ([inserted (buffers:piece-document (buffers:edit-inserted edit))])
         (let loop ([p 0])
           (or (fx= p (document:length inserted))
               (and (char? (document:token inserted p)) (loop (fx+ p 1))))))))

(buffers:define-kind list (content nodes) (consent %keep-rows) (keymap list-keys) (draw %draw-list))

(buffers:define-kind %list-row (content atom) (draw %draw-list-row))

(define %list-kind (buffers:kind-name (buffers:constructor-kind list)))

(define %row-kind (buffers:kind-name (buffers:constructor-kind %list-row)))

(define (%check-list who b node)
  (let ([current (and (document:node? node)
                      (let ([doc (buffers:document b)] [s (document:node-start node)])
                        (and (fx< s (document:length doc)) (document:token doc s))))])
    (unless (and (list-node? current) (fx= (document:node-end current) (document:node-end node)))
      (assertion-violation who "not a list of the buffer" node))
    (unless (memq (document:node-attribute current 'click 'choose) '(choose select))
      (assertion-violation who "a list's click is neither choose nor select" (document:node-attribute current 'click #f)))
    current))

(define (%check-view who view)
  (unless (views:view? view)
    (assertion-violation who "not a view" view))
  (or (views:buffer view)
      (assertion-violation who "the view shows no buffer" view)))

(define (%check-count who n)
  (unless (and (fixnum? n) (fx>= n 0))
    (assertion-violation who "not a count" n)))

(define (%no-heading i) #f)

;; The rows are not the buffer's text, so writing them is silent.
(define (%write-rows! b node start end count generation)
  (buffers:with-silent-edits b
    (buffers:splice! b start end (document:repeat (document:from-datum (row-datum generation)) count))))

;; Each view selecting a row keeps its index, clamped to the new rows, and
;; shows it, rather than whatever row took its place.
(define set-rows!
  (case-lambda
    [(buffer node count draw-row choose) (set-rows! buffer node count draw-row choose %no-heading)]
    [(buffer node count draw-row choose heading)
     (unless (buffers:buffer? buffer)
       (assertion-violation 'ui:set-rows! "not a buffer" buffer))
     (%check-count 'ui:set-rows! count)
     (unless (procedure? draw-row)
       (assertion-violation 'ui:set-rows! "not a procedure" draw-row))
     (unless (procedure? choose)
       (assertion-violation 'ui:set-rows! "not a procedure" choose))
     (unless (procedure? heading)
       (assertion-violation 'ui:set-rows! "not a procedure" heading))
     (let* ([node (%check-list 'ui:set-rows! buffer node)]
            [state (set-list-state! buffer node count draw-row heading choose)]
            [s (document:node-start node)]
            [selections (fold-left (lambda (acc v)
                                     (let ([i (selected-index node (views:point v))])
                                       (if i (cons (cons v i) acc) acc)))
                                   '() (views:showing buffer))])
       (%write-rows! buffer node (fx+ s 1) (fx- (document:node-end node) 1) count (rows-generation state))
       (unless (fx= count 0)
         (let ([node (document:token (buffers:document buffer) s)])
           (for-each (lambda (sel) (views:set-point! (car sel) (index-position node (fxmin (cdr sel) (fx- count 1)))))
                     selections))))]))

(define (add-rows! buffer node count)
  (unless (buffers:buffer? buffer)
    (assertion-violation 'ui:add-rows! "not a buffer" buffer))
  (%check-count 'ui:add-rows! count)
  (let* ([node (%check-list 'ui:add-rows! buffer node)]
         [state (or (list-state buffer node) (assertion-violation 'ui:add-rows! "the list has no rows set" node))]
         [end (fx- (document:node-end node) 1)])
    (unless (fx= count 0)
      (%write-rows! buffer node end end count (rows-generation state))
      (rows-count-set! state (fx+ (rows-count state) count)))))

(define (selected-row node view)
  (let ([b (%check-view 'ui:selected-row view)])
    (selected-index (%check-list 'ui:selected-row b node) (views:point view))))

(define (select-row! node view index)
  (let ([b (%check-view 'ui:select-row! view)])
    (unless (and (fixnum? index) (fx>= index 0))
      (assertion-violation 'ui:select-row! "not a row index" index))
    (let* ([node (%check-list 'ui:select-row! b node)] [n (row-count node)])
      (unless (fx= n 0)
        (views:set-point! view (index-position node (fxmin index (fx- n 1))))))))

;; A list that cannot show all its first rows in most lines takes them
;; all, since the line a heading needs may be the one left over.
(define (list-lines buffer node most)
  (unless (buffers:buffer? buffer)
    (assertion-violation 'ui:list-lines "not a buffer" buffer))
  (unless (and (fixnum? most) (fx> most 0))
    (assertion-violation 'ui:list-lines "not a positive count" most))
  (let* ([node (%check-list 'ui:list-lines buffer node)] [state (list-state buffer node)]
         [n (if state (fxmin (rows-count state) (row-count node)) 0)])
    (let loop ([i 0] [lines 0] [before #f])
      (cond
        [(fx> lines most) most]
        [(fx= i n) lines]
        [else
         (let ([h (heading-of state i)])
           (loop (fx+ i 1) (fx+ lines 1 (if (and h (not (and before (string=? before h)))) 1 0)) h))]))))

(define (describe-list node view)
  (let* ([b (%check-view 'ui:describe-list view)] [node (%check-list 'ui:describe-list b node)]
         [i (selected-index node (views:point view))])
    (and i (format "row ~a of ~a" (fx+ i 1) (row-count node)))))

(define (%list-here who)
  (let ([v (views:current)])
    (unless v
      (assertion-violation who "no view is current"))
    (let ([node (list-at v (views:point v))])
      (unless node
        (assertion-violation who "the cursor is in no list"))
      (values v node))))

(define (%move-row who n)
  (unless (fixnum? n)
    (assertion-violation who "not a count" n))
  (let-values ([(v node) (%list-here who)])
    (let ([i (selected-row node v)])
      (when i (select-row! node v (fxmax 0 (fx+ i n)))))))

(commands:define-command (next-row [n (commands:prefix-number)])
  "Selects the row n after the selected one in the list holding the cursor, stopping at the last."
  (%move-row 'ui:next-row n))

(commands:define-command (previous-row [n (commands:prefix-number)])
  "Selects the row n before the selected one in the list holding the cursor, stopping at the first."
  (%move-row 'ui:previous-row (fx- 0 n)))

(define (%choose! v node i)
  (let ([state (list-state (views:buffer v) node)])
    (when (and state (not (rows-failed? state)) (fx< i (rows-count state)))
      (with-exception-handler
        (lambda (c)
          (when (failure? c) (rows-failed?-set! state #t))
          (raise-continuable c))
        (lambda () ((rows-choose state) i))))))

;; A click on a heading names the list's own node, whose position views
;; gives as its first row's, so the clicked node, not the position, tells
;; a row from a heading.
(commands:define-command (choose-row)
  "Calls the list's choose procedure with its selected row; run by a click, selects and chooses the row clicked, and does nothing for a click on no row, such as on a heading."
  (let ([posn (clicked-posn)])
    (if posn
        (let* ([v (views:posn-view posn)] [p (views:posn-point posn)] [b (views:buffer v)]
               [node (and b p (row-atom? (views:posn-node posn)) (list-at v p))]
               [i (and node (selected-index node p))])
          (when i
            (views:set-point! v p)
            (%choose! v node i)))
        (let-values ([(v node) (%list-here 'ui:choose-row)])
          (let ([i (selected-row node v)])
            (when i (%choose! v node i)))))))

(tables:define-table section-initial-visibility
  "Section types, as keys, to show or hide: the visibility a section of that type starts with in a view when it has no hidden attribute.")

(hooks:define-hook section-visibility-choosers
  "Called with a view and a section; the first entry that returns show or hide, not #f, decides the visibility the view first gives the section.")

(hooks:define-hook section-moved
  "Called with the view and the section at point, or #f, after each section motion command and each other command that changed the section at point.")

(options:define-option highlight-current-section? #t boolean? "Whether the section at point is highlighted.")

(hooks:define-hook section-heading-adornments
  "Called with a view and a section as its heading is drawn; each entry returns HTML drawn after the heading, which is no text of the buffer, or #f.")

(tables:define-table section-keymap "Keys in buffers of ui:section-mode and of the modes derived from it.")

(tables:define-table %section-chevron-keys)

(hooks:define-hook section-mode-hook "Called in each buffer that turns on ui:section-mode.")

(modes:define-major-mode section-mode
  (parent modes:special)
  (lighter "Sections")
  (keymap section-keymap)
  (hook section-mode-hook)
  (plugin-only #t))

(module %sections
  (section-node? section-at-position enclosing-section heading-node heading-start heading-end section-sections
   top-sections next-sibling previous-sibling identity-of walk-sections folded-at? hidden-in? hide! show!
   settle-visibility! repair-after-edit! opened! in-heading? empty-body? record-section! current-section-of)

  (define (section-node? n)
    (and (document:node? n) (not (document:atom? n)) (eq? (document:node-kind n) %section-kind)))

  (define (enclosing-section doc p)
    (let loop ([n (and (fx< p (document:length doc)) (document:enclosing doc p))])
      (cond
        [(not n) #f]
        [(section-node? n) n]
        [else (loop (document:enclosing doc (document:node-start n)))])))

  ;; A position before a section's opening is its parent's, so the
  ;; innermost section holding a position is the one whose content does.
  (define (section-at-position doc p) (enclosing-section doc p))

  (define (heading-node section)
    (let ([first #f] [at (fx+ (document:node-start section) 1)])
      (document:for-each-child section at (fx+ at 1) (lambda (child at) (set! first child)))
      first))

  (define (heading-start section) (fx+ (document:node-start (heading-node section)) 1))

  ;; The heading's line break, where a hidden section's fold starts, so
  ;; the cursor can rest at the end of the heading and nowhere in the
  ;; body.
  (define (heading-end section) (fx- (document:node-end (heading-node section)) 2))

  (define (in-heading? section p)
    (fx<= (heading-start section) p (heading-end section)))

  (define (empty-body? section)
    (fx= (document:node-end (heading-node section)) (fx- (document:node-end section) 1)))

  ;; A section is a block, and a node holding text holds no block, so a
  ;; walk leaves a node at its first text.
  (define (for-each-block n start end proc)
    (call/1cc
      (lambda (k)
        (document:for-each-child n start end
          (lambda (child at)
            (cond
              [(string? child) (k (void))]
              [(not (document:atom? child)) (proc child)]))))))

  (define (sections-below node)
    (let ([found '()])
      (let walk ([n node])
        (for-each-block n (document:node-start n) (document:node-end n)
          (lambda (child)
            (if (section-node? child)
                (set! found (cons child found))
                (walk child)))))
      (reverse found)))

  (define (section-sections section) (sections-below section))

  (define (top-sections doc)
    (if (fx= (document:length doc) 0) '() (sections-below (document:token doc 0))))

  (define (siblings doc section)
    (let ([parent (enclosing-section doc (document:node-start section))])
      (if parent (section-sections parent) (top-sections doc))))

  (define (same? a b) (fx= (document:node-start a) (document:node-start b)))

  (define (next-sibling doc section)
    (let loop ([ss (siblings doc section)])
      (cond
        [(null? ss) #f]
        [(same? (car ss) section) (and (pair? (cdr ss)) (cadr ss))]
        [else (loop (cdr ss))])))

  (define (previous-sibling doc section)
    (let loop ([ss (siblings doc section)] [before #f])
      (cond
        [(null? ss) #f]
        [(same? (car ss) section) before]
        [else (loop (cdr ss) (car ss))])))

  (define (key-of section)
    (cons (document:node-attribute section 'type) (document:node-attribute section 'value)))

  (define (identity-of doc section)
    (let loop ([s section] [acc '()])
      (if s
          (loop (enclosing-section doc (document:node-start s)) (cons (key-of s) acc))
          (reverse acc))))

  (define (walk-below node identity proc)
    (let walk ([n node] [identity identity])
      (for-each-block n (document:node-start n) (document:node-end n)
        (lambda (child)
          (if (section-node? child)
              (let ([identity (cons (key-of child) identity)])
                (proc child identity)
                (walk child identity))
              (walk child identity))))))

  (define (walk-sections doc proc)
    (when (fx> (document:length doc) 0)
      (walk-below (document:token doc 0) '() proc)))

  (define (folds-of view section) (views:folds-at view (heading-end section)))

  (define (own-fold? section folds)
    (let ([start (heading-end section)])
      (exists (lambda (f) (fx= (car f) start)) folds)))

  (define (folded-at? view section) (own-fold? section (folds-of view section)))

  ;; A section with no body has nothing to hide, as in Magit; a fold
  ;; there would hold only the heading's line break.
  (define (add-fold! view section)
    (unless (empty-body? section)
      (let ([start (heading-end section)] [end (fx- (document:node-end section) 1)])
        (when (fx< start (views:point view) end)
          (views:set-point! view (heading-start section)))
        (views:fold! view start end))))

  ;; views:unfold! opens every fold holding the position, so the others
  ;; are put back.
  (define (remove-fold! view section folds)
    (let ([start (heading-end section)])
      (views:unfold! view start)
      (for-each (lambda (f) (unless (fx= (car f) start) (views:fold! view (car f) (cdr f)))) folds)))

  ;; Each view's visibility of each section of a buffer, by identity, as
  ;; Magit keeps it: folds alone lose it, since a refresh that replaces a
  ;; heading's line break or a closing moves or drops the fold, and a
  ;; section that goes and comes back has none. The version is the
  ;; buffer's, once the view's folds follow the record.
  (define-record-type visibilities
    (sealed #t)
    (fields table (mutable version)))

  (define records (make-weak-eq-hashtable))

  (define (visibilities-of view buffer)
    (let ([buffers (or (eq-hashtable-ref records view #f)
                       (let ([t (make-weak-eq-hashtable)]) (eq-hashtable-set! records view t) t))])
      (or (eq-hashtable-ref buffers buffer #f)
          (let ([r (make-visibilities (make-hashtable equal-hash equal?) #f)])
            (eq-hashtable-set! buffers buffer r)
            r))))

  (define (first-visibility view section)
    (or (exists (lambda (entry)
                  (let ([v (entry view section)])
                    (and (memq v '(show hide)) v)))
                (hooks:entries section-visibility-choosers))
        (let ([hidden (document:node-attribute section 'hidden 'none)])
          (cond
            [(eq? hidden 'none) (tables:ref section-initial-visibility (document:node-attribute section 'type) 'show)]
            [hidden 'hide]
            [else 'show]))))

  ;; A section with no record keeps a fold the view already has, as one
  ;; views restores with a buffer it showed before, or one made before
  ;; this module was reloaded.
  (define (visibility view record section identity folds)
    (let ([table (visibilities-table record)])
      (or (hashtable-ref table identity #f)
          (let ([v (if (own-fold? section (or folds (folds-of view section))) 'hide (first-visibility view section))])
            (hashtable-set! table identity v)
            v))))

  (define (record! view section v)
    (let ([b (views:buffer view)])
      (hashtable-set! (visibilities-table (visibilities-of view b)) (identity-of (buffers:document b) section) v)))

  ;; Folds inside a hidden section are left as they are: showing it
  ;; derives them again.
  (define (derive! view record section identity hidden-above?)
    (if hidden-above?
        (begin (visibility view record section identity #f) #t)
        (let* ([folds (folds-of view section)] [folded? (own-fold? section folds)]
               [hidden? (eq? (visibility view record section identity folds) 'hide)])
          (cond
            [(and hidden? (not folded?)) (add-fold! view section)]
            [(and folded? (not hidden?)) (remove-fold! view section folds)])
          hidden?)))

  (define (derive-below! view record node identity)
    (let walk ([n node] [identity identity])
      (for-each-block n (document:node-start n) (document:node-end n)
        (lambda (child)
          (if (section-node? child)
              (let ([identity (cons (key-of child) identity)])
                (unless (derive! view record child identity #f)
                  (walk child identity)))
              (walk child identity))))))

  ;; A view's fold answers for what it shows, since views opens a fold
  ;; that holds a cursor; the record answers inside a hidden section.
  (define (hidden-in? view section)
    (or (folded-at? view section)
        (let* ([b (views:buffer view)] [doc (buffers:document b)])
          (and (eq? (visibility view (visibilities-of view b) section (identity-of doc section) #f) 'hide)
               (let up ([s (enclosing-section doc (document:node-start section))])
                 (and s (or (hidden-in? view s) (up (enclosing-section doc (document:node-start s))))))))))

  (define (hide! view section)
    (record! view section 'hide)
    (unless (folded-at? view section)
      (add-fold! view section)))

  ;; As magit-section-show, the children take the visibility the view
  ;; recorded for them.
  (define (show! view section)
    (let* ([b (views:buffer view)] [record (visibilities-of view b)] [table (visibilities-table record)]
           [identity (identity-of (buffers:document b) section)] [folds (folds-of view section)]
           [folded? (own-fold? section folds)]
           [hidden? (or folded? (eq? (hashtable-ref table identity #f) 'hide))])
      (hashtable-set! table identity 'show)
      (when hidden?
        (when folded? (remove-fold! view section folds))
        (derive-below! view record section identity))))

  ;; As magit-section-show when a search or motion opens a section, so
  ;; a refresh keeps it open. A cursor's opening is told after the draw,
  ;; and a refresh in between may have hidden the section again.
  (define (opened! view start)
    (let* ([b (views:buffer view)] [s (section-at-position (buffers:document b) start)])
      (when (and s (fx= (heading-end s) start) (not (folded-at? view s)))
        (let ([record (visibilities-of view b)] [identity (identity-of (buffers:document b) s)])
          (hashtable-set! (visibilities-table record) identity 'show)
          (settle-visibility! view)
          (derive-below! view record s identity)))))

  ;; An edit moves or strands folds only where it begins and ends. A
  ;; section whose opening it inserted has new identities inside it; a
  ;; section it only enters keeps its own.
  (define (repair! view record doc start end same-key?)
    (let ([n (document:length doc)])
      (views:unfold! view start)
      (views:unfold! view end)
      (when (fx< start n)
        (let walk ([node (document:token doc 0)] [identity '()] [hidden-above? #f])
          (for-each-block node start (fxmin n (fxmax end (fx+ start 1)))
            (lambda (child)
              (let ([at (document:node-start child)])
                (cond
                  [(fx>= at end) (void)]
                  [(not (section-node? child)) (walk child identity hidden-above?)]
                  [(fx< at start)
                   (let ([identity (cons (key-of child) identity)])
                     (walk child identity (derive! view record child identity hidden-above?)))]
                  [else
                   (let ([identity (cons (key-of child) identity)])
                     (unless (or (derive! view record child identity hidden-above?) same-key?)
                       (derive-below! view record child identity)))]))))))))

  ;; An edit that replaces only a section's opening, keeping its type and
  ;; value, changes no identity inside it.
  (define (same-key-opening? edit)
    (let ([removed (buffers:piece-document (buffers:edit-removed edit))]
          [inserted (buffers:piece-document (buffers:edit-inserted edit))])
      (and (fx= (document:length removed) 1) (fx= (document:length inserted) 1)
           (let ([old (document:token removed 0)] [new (document:token inserted 0)])
             (and (section-node? old) (section-node? new) (equal? (key-of old) (key-of new)))))))

  (define (repair-after-edit! view buffer edit)
    (let ([record (visibilities-of view buffer)] [version (buffers:edit-version edit)])
      (when (eqv? (visibilities-version record) (fx- version 1))
        (when (buffers:edit-moves? edit)
          (let ([start (buffers:edit-start edit)])
            (repair! view record (buffers:document buffer) start
                     (fx+ start (buffers:piece-length (buffers:edit-inserted edit)))
                     (same-key-opening? edit))))
        (visibilities-version-set! record version))))

  ;; views keeps the folds of a buffer a view showed before, moved by the
  ;; edits made since, so those edits can have stranded them as any edit
  ;; can.
  (define (settle-visibility! view)
    (let ([b (views:buffer view)])
      (when b
        (let ([record (visibilities-of view b)] [now (buffers:version b)])
          (unless (eqv? (visibilities-version record) now)
            (let ([doc (buffers:document b)]
                  [missed (and (visibilities-version record) (buffers:edits-since b (visibilities-version record)))])
              (cond
                [missed
                 (for-each
                   (lambda (e)
                     (when (buffers:edit-moves? e)
                       (let ([start (buffers:edit-start e)] [version (buffers:edit-version e)])
                         (repair! view record doc (buffers:map-position b start version)
                                  (buffers:map-position b (fx+ start (buffers:piece-length (buffers:edit-inserted e))) version)
                                  #f))))
                   missed)]
                [(fx> (document:length doc) 0) (derive-below! view record (document:token doc 0) '())]))
            (visibilities-version-set! record now))))))

  (define last-sections (make-weak-eq-hashtable))

  (define (current-section-of view)
    (let ([b (views:buffer view)])
      (and b (section-at-position (buffers:document b) (views:point view)))))

  (define (record-section! view)
    (let* ([b (views:buffer view)] [s (current-section-of view)]
           [identity (and s (identity-of (buffers:document b) s))]
           [changed? (not (equal? identity (eq-hashtable-ref last-sections view 'none)))])
      (eq-hashtable-set! last-sections view identity)
      changed?)))

(import %sections)

(define (%section-buffer? b)
  (and b (buffers:live? b) (modes:derived? (modes:major-mode b) section-mode)))

(define (%draw-section node view)
  (let* ([b (views:buffer view)]
         [current? (and (highlight-current-section?) b
                        (let ([s (section-at-position (buffers:document b) (views:point view))])
                          (and s (fx= (document:node-start s) (document:node-start node)))))]
         [hidden? (folded-at? view node)])
    (haml (:section ([class (string-append "ui-section" (if current? " current" "") (if hidden? " hidden" ""))]
                     [data-type (symbol->string (document:node-attribute node 'type))])
            (views:draw-children view node)))))

(define (%draw-section-heading node view)
  (let* ([b (views:buffer view)]
         [section (and b (enclosing-section (buffers:document b) (document:node-start node)))]
         [hidden? (and section (folded-at? view section))]
         [chevron (if (and section (empty-body? section))
                      '()
                      (haml (:span.ui-section-chevron ([data-keymap (views:keymap-mark %section-chevron-keys)] [aria-hidden "true"])
                              (if hidden? "▸" "▾"))))]
         [ellipsis (if hidden? (haml (:span.ui-section-ellipsis "…")) '())]
         [adornments (if section
                         (fold-right (lambda (entry acc) (let ([h (entry view section)]) (if h (cons h acc) acc)))
                                     '() (hooks:entries section-heading-adornments))
                         '())])
    (haml (:div.ui-section-heading
            chevron
            (views:draw-children view node)
            ellipsis
            adornments))))

(buffers:define-kind %section (content nodes) (draw %draw-section))

(buffers:define-kind %section-heading (draw %draw-section-heading))

(buffers:define-kind %section-text)

(define %section-kind (buffers:kind-name (buffers:constructor-kind %section)))

(define (%with-newline s)
  (if (and (fx> (string-length s) 0) (char=? (string-ref s (fx- (string-length s) 1)) #\newline))
      s
      (string-append s "\n")))

(define (section attributes heading . body)
  (unless (and (list? attributes) (for-all (lambda (a) (and (pair? a) (symbol? (car a)))) attributes))
    (assertion-violation 'ui:section "not an association list of attributes" attributes))
  (let ([type (assq 'type attributes)])
    (unless (and type (symbol? (cdr type)))
      (assertion-violation 'ui:section "a section's type is not a symbol" (and type (cdr type))))
    (unless (or (string? heading) (list? heading))
      (assertion-violation 'ui:section "not a heading's text or inline content" heading))
    (let* ([value (cond [(assq 'value attributes) => cdr] [else #f])]
           [attributes (if (assq 'value attributes) attributes (append attributes '((value . #f))))]
           [attributes (if (assq 'key attributes) attributes (append attributes `((key . (,(cdr type) . ,value)))))])
      (apply %section attributes
             (apply %section-heading '() (append (if (string? heading) `(,heading) heading) '("\n")))
             (map (lambda (item) (if (string? item) (%section-text '() (%with-newline item)) item)) body)))))

(define (%check-view-buffer who view)
  (unless (views:view? view)
    (assertion-violation who "not a view" view))
  (or (views:buffer view)
      (assertion-violation who "the view shows no buffer" view)))

(define (%check-section who section)
  (unless (section-node? section)
    (assertion-violation who "not a section" section)))

(define section-at
  (case-lambda
    [(view)
     (%check-view-buffer 'ui:section-at view)
     (section-at view (views:point view))]
    [(view position)
     (let ([b (%check-view-buffer 'ui:section-at view)])
       (unless (and (fixnum? position) (fx<= 0 position (document:length (buffers:document b))))
         (assertion-violation 'ui:section-at "not a position of the buffer" position))
       (section-at-position (buffers:document b) position))]))

(define (section-type section)
  (%check-section 'ui:section-type section)
  (document:node-attribute section 'type))

(define (section-value section)
  (%check-section 'ui:section-value section)
  (document:node-attribute section 'value))

(define (section-parent section buffer)
  (%check-section 'ui:section-parent section)
  (enclosing-section (buffers:document buffer) (document:node-start section)))

(define (section-children section)
  (%check-section 'ui:section-children section)
  (section-sections section))

(define (section-identity section buffer)
  (%check-section 'ui:section-identity section)
  (identity-of (buffers:document buffer) section))

(define (find-section buffer identity)
  (unless (buffers:buffer? buffer)
    (assertion-violation 'ui:find-section "not a buffer" buffer))
  (call/1cc
    (lambda (k)
      (walk-sections (buffers:document buffer)
        (lambda (section found) (when (equal? found identity) (k section))))
      #f)))

(define (section-heading-start section)
  (%check-section 'ui:section-heading-start section)
  (heading-start section))

;; As Magit's magit-region-sections: the region starts in one section's
;; heading and ends in a later sibling's.
(define (section-selection view)
  (let* ([b (%check-view-buffer 'ui:section-selection view)] [doc (buffers:document b)]
         [ranges (views:region-bounds view)])
    (and (pair? ranges)
         (let* ([start (caar ranges)] [end (cdar ranges)]
                [first (section-at-position doc start)] [last (section-at-position doc end)])
           (and first last (not (fx= (document:node-start first) (document:node-start last)))
                (in-heading? first start) (in-heading? last end)
                (let loop ([s first] [acc '()])
                  (cond
                    [(not s) #f]
                    [(fx= (document:node-start s) (document:node-start last)) (reverse (cons s acc))]
                    [else (loop (next-sibling doc s) (cons s acc))])))))))

(define (section-hidden? view section)
  (%check-view-buffer 'ui:section-hidden? view)
  (%check-section 'ui:section-hidden? section)
  (settle-visibility! view)
  (hidden-in? view section))

(define (hide-section! view section)
  (%check-view-buffer 'ui:hide-section! view)
  (%check-section 'ui:hide-section! section)
  (settle-visibility! view)
  (hide! view section))

(define (show-section! view section)
  (%check-view-buffer 'ui:show-section! view)
  (%check-section 'ui:show-section! section)
  (settle-visibility! view)
  (show! view section))

;; A view's folds follow its record from its first draw of the buffer,
;; so a command or a question before then settles them first.
(define (%section-view who)
  (let ([v (views:current)])
    (unless (and v (views:buffer v))
      (assertion-violation who "no view is current"))
    (settle-visibility! v)
    v))

(define (%moved! view)
  (record-section! view)
  (section-moved view (current-section-of view)))

(define (%goto! view section) (views:set-point! view (heading-start section)))

(define (%last-shown view section)
  (let loop ([s section])
    (let ([children (section-sections s)])
      (if (or (null? children) (hidden-in? view s))
          s
          (loop (car (reverse children)))))))

(define (%forward-target view doc)
  (let* ([p (views:point view)] [s (section-at-position doc p)])
    (or (if s
            (let ([children (section-sections s)])
              (or (and (pair? children) (not (hidden-in? view s)) (car children))
                  (let up ([s s])
                    (and s (or (next-sibling doc s) (up (enclosing-section doc (document:node-start s))))))))
            (find (lambda (t) (fx> (heading-start t) p)) (top-sections doc)))
        (error 'ui:section-forward "No next section"))))

;; Point rests at the stop of the heading's start, which is past it when
;; the heading starts with a node, so the two are compared as places.
(define (%backward-target view doc)
  (let* ([b (views:buffer view)] [p (views:point view)] [s (section-at-position doc p)])
    (cond
      [(and s (not (eqv? (buffers:stop b p) (buffers:stop b (heading-start s))))) s]
      [else
       (let ([previous (if s
                           (previous-sibling doc s)
                           (let ([before (filter (lambda (t) (fx< (heading-start t) p)) (top-sections doc))])
                             (and (pair? before) (car (reverse before)))))])
         (cond
           [previous (%last-shown view previous)]
           [(and s (enclosing-section doc (document:node-start s)))]
           [else (error 'ui:section-backward "No previous section")]))])))

;; Each step moves point, so a count that runs past the last section
;; stops there with the error.
(define (%move-sections! who n forward backward)
  (unless (fixnum? n)
    (assertion-violation who "not a count" n))
  (let ([v (%section-view who)] [moved? #f])
    (dynamic-wind
      void
      (lambda ()
        (let loop ([k (fxabs n)])
          (unless (fx= k 0)
            (let ([doc (buffers:document (views:buffer v))])
              (%goto! v ((if (fx>= n 0) forward backward) v doc))
              (set! moved? #t)
              (loop (fx- k 1))))))
      (lambda () (when moved? (%moved! v))))))

(define (%forward-sibling-target view doc)
  (let ([s (section-at-position doc (views:point view))])
    (or (and s (next-sibling doc s)) (%forward-target view doc))))

(define (%backward-sibling-target view doc)
  (let ([s (section-at-position doc (views:point view))])
    (or (and s (previous-sibling doc s)) (%backward-target view doc))))

(commands:define-command (section-forward [n (commands:prefix-number)])
  "Moves point to the next visible section's heading: the first child of a shown section, else the next sibling, else the parent's next sibling; n times."
  (%move-sections! 'ui:section-forward n %forward-target %backward-target))

(commands:define-command (section-backward [n (commands:prefix-number)])
  "Moves point to the start of the section holding it; at that start, to the previous visible section; n times."
  (%move-sections! 'ui:section-backward n %backward-target %forward-target))

(commands:define-command (section-forward-sibling [n (commands:prefix-number)])
  "Moves point to the next sibling section's heading, or as ui:section-forward when there is none; n times."
  (%move-sections! 'ui:section-forward-sibling n %forward-sibling-target %backward-sibling-target))

(commands:define-command (section-backward-sibling [n (commands:prefix-number)])
  "Moves point to the previous sibling section's heading, or as ui:section-backward when there is none; n times."
  (%move-sections! 'ui:section-backward-sibling n %backward-sibling-target %forward-sibling-target))

(commands:define-command (section-up)
  "Moves point to the parent section's heading; from a top-level section, to the start of the buffer."
  (let* ([v (%section-view 'ui:section-up)] [doc (buffers:document (views:buffer v))]
         [s (section-at-position doc (views:point v))])
    (unless s
      (error 'ui:section-up "No parent section"))
    (let ([parent (enclosing-section doc (document:node-start s))])
      (if parent
          (%goto! v parent)
          (views:set-point! v 0)))
    (%moved! v)))

(define (%section-here who)
  (let* ([v (%section-view who)] [s (section-at-position (buffers:document (views:buffer v)) (views:point v))])
    (values v s)))

(commands:define-command (section-toggle)
  "Shows the section at point when hidden, else hides it."
  (let-values ([(v s) (%section-here 'ui:section-toggle)])
    (cond
      [(not s) (error 'ui:section-toggle "Cannot hide root section")]
      [(hidden-in? v s) (show! v s)]
      [else (hide! v s)])))

(define (%show-children! v children depth)
  (for-each
    (lambda (child)
      (show! v child)
      (cond
        [(not depth) (%show-children! v (section-sections child) #f)]
        [(fx> depth 0) (%show-children! v (section-sections child) (fx- depth 1))]
        [else (hide! v child)]))
    children))

(define (%show-headings! v children)
  (for-each
    (lambda (child)
      (show! v child)
      (when (or (pair? (section-sections child)) (not (%has-body? child)))
        (%show-headings! v (section-sections child))))
    children))

(define (%has-body? section)
  (fx> (fx- (document:node-end section) 1) (fx+ (heading-end section) 2)))

(define (%hidden-body? v section)
  (let ([children (section-sections section)])
    (if (pair? children)
        (exists (lambda (c) (%hidden-body? v c)) children)
        (and (%has-body? section) (hidden-in? v section)))))

(define (%cycle-children! v children hide-all!)
  (cond
    [(and (exists (lambda (c) (hidden-in? v c)) children)
          (exists (lambda (c) (pair? (section-sections c))) children))
     (%show-headings! v children)]
    [(exists (lambda (c) (%hidden-body? v c)) children)
     (%show-children! v children #f)]
    [else (hide-all!)]))

(define (%cycle-global! v)
  (let ([tops (top-sections (buffers:document (views:buffer v)))])
    (%cycle-children! v tops (lambda () (for-each (lambda (s) (hide! v s)) tops)))))

(commands:define-command (section-cycle)
  "Cycles the section at point: hidden, then shown with its children hidden, then its children's headings shown, then everything shown."
  (let-values ([(v s) (%section-here 'ui:section-cycle)])
    (cond
      [(not s) (%cycle-global! v)]
      [(hidden-in? v s)
       (show! v s)
       (for-each (lambda (c) (hide! v c)) (section-sections s))]
      [else (%cycle-children! v (section-sections s) (lambda () (hide! v s)))])))

(commands:define-command (section-cycle-global)
  "Cycles every top-level section: their headings shown, everything shown, or all hidden, as Magit's rule picks."
  (%cycle-global! (%section-view 'ui:section-cycle-global)))

(define (%typed-level)
  (let* ([key (keys:command-event)]
         [c (and (string? key) (fx> (string-length key) 0) (string-ref key (fx- (string-length key) 1)))])
    (or (and c (char<=? #\1 c #\9) (fx- (char->integer c) (char->integer #\0)))
        (assertion-violation 'ui:section-show-level "no digit typed" key))))

(define (%level-of doc section) (length (identity-of doc section)))

(define (%check-level who level)
  (unless (and (fixnum? level) (fx> level 0))
    (assertion-violation who "not a level" level)))

(commands:define-command (section-show-level [level (%typed-level)])
  "Shows the sections around point down to LEVEL and hides deeper ones; point moves to the enclosing section of that level."
  (%check-level 'ui:section-show-level level)
  (let-values ([(v s) (%section-here 'ui:section-show-level)])
    (let ([doc (buffers:document (views:buffer v))])
      (let loop ([s s] [i (if s (%level-of doc s) 0)])
        (cond
          [(not s)
           (%show-children! v (top-sections doc) (fx- level 1))
           (views:set-point! v 0)]
          [(fx< i level)
           (show! v s)
           (%show-children! v (section-sections s) (fx- (fx- level i) 1))
           (%goto! v s)]
          [(fx= i level) (hide! v s) (%goto! v s)]
          [else (loop (enclosing-section doc (document:node-start s)) (fx- i 1))])))))

(commands:define-command (section-show-level-everywhere [level (%typed-level)])
  "Shows every section of the buffer down to LEVEL and hides deeper ones; point moves to the enclosing section of that level."
  (%check-level 'ui:section-show-level-everywhere level)
  (let-values ([(v s) (%section-here 'ui:section-show-level-everywhere)])
    (let ([doc (buffers:document (views:buffer v))])
      (let loop ([s s])
        (when (and s (fx> (%level-of doc s) level))
          (let ([parent (enclosing-section doc (document:node-start s))])
            (%goto! v parent)
            (loop parent))))
      (%show-children! v (top-sections doc) (fx- level 1)))))

(commands:define-command (section-mouse-toggle [event (keys:command-event)])
  "Toggles the section whose heading's chevron was clicked."
  (let* ([posn (and (keys:event? event) (keys:event-start event))]
         [v (and posn (views:posn-view posn))] [p (and posn (views:posn-point posn))]
         [b (and v (views:buffer v))]
         [s (and b p (section-at-position (buffers:document b) p))])
    (when s
      (settle-visibility! v)
      (views:set-point! v (heading-start s))
      (if (hidden-in? v s) (show! v s) (hide! v s)))))

(define (%settle-after-edit buffer edit)
  (when (%section-buffer? buffer)
    (for-each (lambda (v) (repair-after-edit! v buffer edit)) (views:showing buffer))))

(define (%note-opened view start end)
  (when (%section-buffer? (views:buffer view))
    (opened! view start)))

(define %section-buffers (make-weak-eq-hashtable))

;; A dropped view is no longer among the views showing a buffer, so the
;; views a hook is handed are looked for there, never asked for their
;; buffer.
(define (%settle-when-drawn view buffer)
  (when (and (%section-buffer? buffer) (memq view (views:showing buffer)))
    (settle-visibility! view)))

(define (%settle-on-mode)
  (let ([b (buffers:current)])
    (when b
      (eq-hashtable-set! %section-buffers b #t)
      (for-each settle-visibility! (views:showing b)))))

(define (%note-section-change command)
  (let ([v (views:current)])
    (when v
      (vector-for-each
        (lambda (b)
          (when (and (%section-buffer? b) (memq v (views:showing b)) (record-section! v))
            (section-moved v (current-section-of v))))
        (hashtable-keys %section-buffers)))))

(define (%draw-showcase node view)
  (haml (:article (views:draw-children view node))))

(define (%draw-showcase-heading node view)
  (haml (:div.ui-showcase-heading (views:draw-children view node))))

;; Hover and pressed last only while the pointer is on a real button or
;; link, so a sample holds one.
(define (%draw-state-sample node view)
  (let ([state (document:node-attribute node 'state)])
    (haml (:button ([class (if (eq? (document:node-attribute node 'of) 'link) "ui-link" "ui-button")]
                    [type "button"] [tabindex "-1"]
                    [data-ui-state (symbol->string state)])
            (document:node-attribute node 'label)))))

(define (%draw-helper-sample node view)
  (case (document:node-attribute node 'of)
    [(label) (label "A label")]
    [(label-class) (label "A label with a class" "ui-showcase-muted")]
    [(row) (row (label "notes.org") (label "~/notes" "ui-showcase-muted") (label "2 KB" "ui-showcase-faint"))]))

(define (%draw-chosen node view)
  (label (document:node-attribute node 'name "nothing yet")))

(buffers:define-kind %showcase (content nodes) (draw %draw-showcase))
(buffers:define-kind %showcase-heading (draw %draw-showcase-heading))
(buffers:define-kind %showcase-text)
(buffers:define-kind %state-sample (content atom) (draw %draw-state-sample))
(buffers:define-kind %helper-sample (content atom) (draw %draw-helper-sample))
(buffers:define-kind %chosen (content atom) (draw %draw-chosen))
(buffers:define-layer %read-only (read-only))

(define %showcase-kind (buffers:kind-name (buffers:constructor-kind %showcase)))
(define %chosen-kind (buffers:kind-name (buffers:constructor-kind %chosen)))

(define (%times verb n)
  (string-append verb " " (number->string n) (if (= n 1) " time" " times")))

;; The count lives in the button's attributes, so it outlives a reload of
;; this module as the buffer does.
(commands:define-command (%count-push [button (pushed-button)])
  "Counts a push of a showcase button or link in its label."
  (let ([n (+ (document:node-attribute button 'n 0) 1)] [verb (document:node-attribute button 'verb)])
    (buffers:splice! (buffers:current) (document:node-start button) (document:node-end button)
      (document:from-datum `(,(document:node-kind button) ((n . ,n) (verb . ,verb)) ,(%times verb n))))))

(define-button %sample-button %count-push)

(define-link %sample-link %count-push)

(define %short-rows
  '#(("init.ss" . "configuration") ("notes.org" . "outline") ("todo.txt" . "text") ("ui.sls" . "plugin")
     ("ui.css" . "stylesheet") ("README.md" . "markdown") ("Makefile" . "build") ("build.ss" . "scheme")))

(define %long-rows
  (let ([v (make-vector 300)])
    (do ([i 0 (fx+ i 1)]) ((fx= i 300) v)
      (vector-set! v i (cons (string-append "Row " (number->string (fx+ i 1)))
                             (string-append (number->string (fx+ i 1)) " of 300"))))))

(define (%showcase-group i)
  (if (fx< i 3) "Notes" "Project"))

(define (%draw-showcase-row r)
  (row (label (car r)) (label (cdr r) "ui-showcase-muted")))

(define (%showcase-node b match?)
  (call/1cc
    (lambda (k)
      (let walk ([n (document:token (buffers:document b) 0)])
        (document:for-each-child n 0 (document:length (buffers:document b))
          (lambda (child at)
            (when (document:node? child)
              (when (match? child) (k child))
              (unless (document:atom? child) (walk child))))))
      #f)))

(define (%showcase-list b rows)
  (%showcase-node b (lambda (n) (and (list-node? n) (eq? (document:node-attribute n 'rows) rows)))))

(define (%show-chosen! b r)
  (let ([chosen (%showcase-node b (lambda (n) (eq? (document:node-kind n) %chosen-kind)))])
    (buffers:splice! b (document:node-start chosen) (document:node-end chosen)
      (document:from-datum (%chosen `((name . ,(car r))))))))

(define (%fill-showcase! b)
  (define (fill! rows name heading)
    (set-rows! b (%showcase-list b name) (vector-length rows)
               (lambda (i) (%draw-showcase-row (vector-ref rows i)))
               (lambda (i) (%show-chosen! b (vector-ref rows i)))
               heading))
  (fill! %short-rows 'short %showcase-group)
  (fill! %long-rows 'long %no-heading))

(define (%showcase-datum)
  (%showcase '()
    (%showcase-text '()
      "Every component and helper of the ui plugin, in each of its states.\n"
      "The buffer is read-only.\n\n")
    (%showcase-heading '() "Buttons: ui:define-button\n")
    (%showcase-text '()
      "normal    " (%sample-button '((n . 0) (verb . "Pushed")) "Push me") "  a click or RET counts\n"
      "hover     " (%state-sample '((of . button) (state . hover) (label . "Push me"))) "\n"
      "pressed   " (%state-sample '((of . button) (state . pressed) (label . "Push me"))) "\n"
      "disabled  " (%sample-button '((n . 0) (verb . "Pushed") (disabled . #t)) "Push me")
      "  a click or RET does nothing\n\n")
    (%showcase-heading '() "Links: ui:define-link\n")
    (%showcase-text '()
      "normal    " (%sample-link '((n . 0) (verb . "Followed")) "Follow me") "  a click or RET counts\n"
      "hover     " (%state-sample '((of . link) (state . hover) (label . "Follow me"))) "\n"
      "disabled  " (%sample-link '((n . 0) (verb . "Followed") (disabled . #t)) "Follow me")
      "  a click or RET does nothing\n\n")
    (%showcase-heading '() "Labels and rows: ui:label, ui:row\n")
    (%showcase-text '()
      "label     " (%helper-sample '((of . label))) "\n"
      "class     " (%helper-sample '((of . label-class))) "\n"
      "A row of three labels, the second muted and the third faint:\n"
      (%helper-sample '((of . row))) "\n")
    (%showcase-heading '() "Lists: ui:list\n")
    (%showcase-text '()
      "C-n and C-p move, RET or a click chooses. Eight rows under two\n"
      "headings. Each window on this buffer selects its own row; split the\n"
      "window to see a list in a window without focus.\n")
    (list '((rows . short)))
    (%showcase-text '() "chosen    " (%chosen '()) "\n\n")
    (%showcase-text '()
      "Three hundred rows: the window scrolls through them and draws only\n"
      "those near what it shows.\n")
    (list '((rows . long)))))

(tables:define-table showcase-keymap "Keys in *Showcase*.")

(hooks:define-hook showcase-mode-hook "Called in each buffer that turns on ui:showcase-mode.")

(modes:define-major-mode showcase-mode
  (parent modes:special)
  (lighter "Showcase")
  (keymap showcase-keymap)
  (hook showcase-mode-hook)
  (plugin-only #t))

(define (%showcase-buffer)
  (let ([b (buffers:find "*Showcase*")])
    (and b (eq? (document:node-kind (document:token (buffers:document b) 0)) %showcase-kind) b)))

;; Read-only, so every edit is this plugin's, and it holds nothing to
;; save.
(define (%make-showcase)
  (let ([b (buffers:make "*Showcase*" (%showcase-datum))])
    (buffers:set-silent! b #t)
    (buffers:add-span! (buffers:layer b %read-only) 0 (document:length (buffers:document b)) '())
    (modes:set-major-mode showcase-mode b)
    (%fill-showcase! b)
    b))

;; Point starts on the first list's first row, so the showcase opens with
;; a selected row and the list's keys active; a view with no measurements
;; would centre that point and hide the buttons above it.
(commands:define-command (showcase)
  "Shows every component and helper of the ui plugin, in each of its states, in the read-only buffer *Showcase*."
  (let ([v (views:current)])
    (unless v
      (assertion-violation 'ui:showcase "no view is current"))
    (let ([b (or (%showcase-buffer) (%make-showcase))])
      (unless (eq? (views:buffer v) b)
        (views:set-buffer! v b)
        (select-row! (%showcase-list b 'short) v 0)
        (views:scroll-to! v 0 (views:align top))))))

(keys:bind! section-keymap "n" section-forward)
(keys:bind! section-keymap "p" section-backward)
(keys:bind! section-keymap "^" section-up)
(keys:bind! section-keymap "M-n" section-forward-sibling)
(keys:bind! section-keymap "M-p" section-backward-sibling)
(keys:bind! section-keymap "TAB" section-toggle)
(keys:bind! section-keymap "C-TAB" section-cycle)
(keys:bind! section-keymap "C-c TAB" section-cycle)
(keys:bind! section-keymap "M-TAB" section-cycle)
(keys:bind! section-keymap "S-TAB" section-cycle-global)
(for-each (lambda (digit)
            (keys:bind! section-keymap digit section-show-level)
            (keys:bind! section-keymap (string-append "M-" digit) section-show-level-everywhere))
          '("1" "2" "3" "4"))
(keys:bind! %section-chevron-keys "<mouse-1>" section-mouse-toggle)
(tables:set! section-initial-visibility 'stashes 'hide)
(hooks:add! section-mode-hook %settle-on-mode)
(hooks:add! buffers:after-edit %settle-after-edit)
(hooks:add! views:drawn-ranges-changed %settle-when-drawn)
(hooks:add! views:fold-opened %note-opened)
(hooks:add! commands:after-command %note-section-change)
(keys:bind! showcase-keymap "g" keys:undefined)
(keys:bind! list-keys "C-n" next-row)
(keys:bind! list-keys "<down>" next-row)
(keys:bind! list-keys "C-p" previous-row)
(keys:bind! list-keys "<up>" previous-row)
(keys:bind! list-keys "RET" choose-row)
(keys:bind! list-click-keys "<mouse-1>" keys:ignore)
(keys:bind! list-click-keys "<mouse-2>" keys:ignore)
;; A press would move point where it lands, and a press on a heading
;; lands on the list's first row, so the release alone selects.
(keys:bind! list-click-keys "<down-mouse-1>" keys:ignore)
(keys:bind! list-click-keys "<drag-mouse-1>" keys:ignore)
(keys:bind! list-click-keys "<drag-mouse-2>" keys:ignore)
(keys:bind! row-keys "<mouse-1>" choose-row)
(keys:bind! row-keys "<mouse-2>" choose-row)
(keys:bind! disabled-keys "<mouse-1>" keys:ignore)
(keys:bind! disabled-keys "<mouse-2>" keys:ignore)
(keys:bind! disabled-keys "RET" keys:ignore)
(keys:bind! disabled-keys "<down-mouse-1>" keys:ignore)
(keys:bind! disabled-keys "<drag-mouse-1>" keys:ignore)
(keys:bind! disabled-keys "<drag-mouse-2>" keys:ignore)
;; Ahead of the entries that find the button kind's own keymap.
(hooks:add! keys:find-keymaps %disabled-keymaps -10)
;; Ahead of the keymaps found by place, which the list's rows and text sit in.
(hooks:add! keys:find-keymaps %choosing-keymaps -5)
(tables:set! views:position-describers list describe-list)
(tables:set! web:stylesheets 'ui "ui/ui.css")
(hooks:add! buffers:killed forget-buffer!)

;; A list's rows are this module's, so a showcase made before a reload
;; gets them again.
(let ([b (%showcase-buffer)])
  (when b (%fill-showcase! b)))
