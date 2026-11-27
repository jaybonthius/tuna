#!tuna
(import (layout) (buffers) (document) (views) (keys) (commands) (web) (haml) (tables))

(module %internals
  (parts tabs-node? holding-tabs holds-locked? same-part? leads-to-locked? place-attribute?)

  (define (parts node)
    (let ([acc '()])
      (document:for-each-child node (fx+ (document:node-start node) 1) (fx- (document:node-end node) 1)
        (lambda (c at) (when (document:node? c) (set! acc (cons c acc)))))
      (reverse acc)))

  (define (tabs-node? node kind)
    (and node (not (document:atom? node)) (eq? (document:node-kind node) kind)))

  (define (holding-tabs p kind)
    (let ([doc (buffers:document layout:buffer)])
      (let climb ([child (let ([t (document:token doc p)]) (and (document:node? t) t))]
                  [n (document:enclosing doc p)])
        (cond
          [(not n) (values #f #f)]
          [(tabs-node? n kind) (values (and child n) child)]
          [else (climb n (document:enclosing doc (document:node-start n)))]))))

  (define (holds-locked? node)
    (or (layout:locked? node)
        (and (not (document:atom? node)) (exists holds-locked? (parts node)))))

  (define (same-part? a b) (fx= (document:node-start a) (document:node-start b)))

  (define (leads-to-locked? node) (layout:locked? (layout:view-node (layout:part-view node))))

  ;; What a view atom says of itself stays with it; the rest describes its
  ;; place, which the tabs container wrapping it takes.
  (define (place-attribute? a) (not (memq (car a) '(view buffer title)))))

(import %internals)

(tables:define-table keymap "The keymap of the tabs in a tabs container's strip.")

(tables:define-table close-keymap "The keymap of a tab's close button.")

;; A tab is drawn as two buttons side by side, since a button may not
;; hold another; the tab's element carries its child's marks, so a click
;; on either names the child. A tablist may own only tabs, so the close
;; button is hidden from assistive technology, which closes a tab by its
;; key instead.
(define (%draw-tabs node children focused draw-child client)
  (let ([shown (or (and focused
                        (find (lambda (c) (same-part? c focused)) children))
                   (car children))])
    (haml (:div.tabs ([class (layout:part-class node)])
            (:div.tabs-strip ([role "tablist"])
              (map (lambda (c)
                     (let ([title (layout:part-title c)])
                       (haml (:div.tab ([data-at (document:node-start c)] [data-to (document:node-end c)]
                                        [data-keymap (views:keymap-mark keymap)])
                               (:button.layout-tabs-label ([type "button"] [role "tab"] [tabindex "-1"]
                                                           [aria-selected (if (eq? c shown) "true" "false")] [data-label title])
                                 title)
                               (:button.layout-tabs-close ([type "button"] [tabindex "-1"] [aria-hidden "true"]
                                                           [data-keymap (views:keymap-mark close-keymap)])
                                 "×")))))
                   children))
            (:div.tabs-panel ([role "tabpanel"] [aria-label (layout:part-title shown)]) (draw-child shown))))))

(layout:define-container container
  (draw %draw-tabs)
  (show-focused))

(define (%kind) (buffers:kind-name (buffers:constructor-kind container)))

(define (%view-tabs view)
  (let ([atom (layout:view-node view)])
    (if atom (holding-tabs (document:node-start atom) (%kind)) (values #f #f))))

(define (add-tab! view b)
  (unless (views:view? view)
    (assertion-violation 'layout-tabs:add-tab! "not a view" view))
  (unless (buffers:buffer? b)
    (assertion-violation 'layout-tabs:add-tab! "not a buffer" b))
  (let ([atom (layout:view-node view)])
    (unless atom
      (assertion-violation 'layout-tabs:add-tab! "not a view in the layout" view))
    (when (layout:locked? atom)
      (assertion-violation 'layout-tabs:add-tab! "a locked view" view))
    (let* ([new (views:make b)]
           [new-datum (vector 'views:view (list (cons 'view (views:id new)) (cons 'buffer (buffers:name b))))])
      (let-values ([(tabs tab) (%view-tabs view)])
        (if tabs
            (let ([at (document:node-end tab)])
              (buffers:replace! layout:buffer at at new-datum))
            (let* ([d (car (document:datums (document:slice (buffers:document layout:buffer)
                                                            (document:node-start atom) (document:node-end atom))))]
                   [attributes (vector-ref d 1)])
              (buffers:replace! layout:buffer (document:node-start atom) (document:node-end atom)
                (container (filter place-attribute? attributes)
                           (vector 'views:view (remp place-attribute? attributes))
                           new-datum)))))
      new)))

(define (%selected-tabs who)
  (let-values ([(tabs tab) (%view-tabs (layout:selected-view))])
    (unless tabs
      (assertion-violation who "the selected view is in no tabs"))
    (values tabs tab)))

(define (%switch-tab! who n sign)
  (unless (and (integer? n) (exact? n))
    (assertion-violation who "not an exact integer" n))
  (let-values ([(tabs tab) (%selected-tabs who)])
    (let* ([stops (filter (lambda (c) (or (same-part? c tab) (not (leads-to-locked? c)))) (parts tabs))]
           [k (let loop ([cs stops] [k 0]) (if (same-part? (car cs) tab) k (loop (cdr cs) (fx+ k 1))))])
      (layout:select! (layout:part-view (list-ref stops (mod (+ k (* sign n)) (length stops))))))))

;; Unlike other display actions this one selects: a tabs container shows
;; the tab holding the view selected last, so an unselected new tab would
;; not be on screen.
(define (display-in-new-tab b)
  (unless (buffers:buffer? b)
    (assertion-violation 'layout-tabs:display-in-new-tab "not a buffer" b))
  (let* ([selected (layout:selected-view)] [atom (layout:view-node selected)])
    (and atom (not (layout:locked? atom))
         (let ([new (add-tab! selected b)])
           (layout:select! new)
           new))))

(commands:define-command (new-tab)
  "Adds a tab after the selected view's tab, showing its buffer, and selects it."
  (let* ([v (layout:selected-view)] [new (add-tab! v (views:buffer v))])
    (views:set-point! new (views:point v))
    (layout:select! new)))

(commands:define-command (close-tab)
  "Deletes the tab holding the selected view, with every part in it."
  (let-values ([(tabs tab) (%selected-tabs 'layout-tabs:close-tab)])
    (layout:delete-part! tab)))

;; A lock binds the user's commands, so a tab holding a locked part stays.
;; Tabs outside the selected view's level are persistent for it, and its
;; level's window history could not bring them back.
(commands:define-command (close-other-tabs)
  "Deletes every tab but the selected view's, in the innermost tabs that hold it, inside its level, except tabs holding a locked part."
  (let loop ()
    (let-values ([(tabs tab) (%selected-tabs 'layout-tabs:close-other-tabs)])
      (unless (fx< (document:node-start (layout:level-of (layout:selected-view))) (document:node-start tabs))
        (assertion-violation 'layout-tabs:close-other-tabs "the selected view is in no tabs inside its level"))
      (let ([other (find (lambda (c) (not (or (same-part? c tab) (holds-locked? c)))) (parts tabs))])
        (when other
          (layout:delete-part! other)
          (loop))))))

(commands:define-command (next-tab [n (commands:prefix-number)])
  "Selects the view the focused children lead to in the tab n after the selected view's tab, cyclically."
  (%switch-tab! 'layout-tabs:next-tab n 1))

(commands:define-command (previous-tab [n (commands:prefix-number)])
  "Selects the view the focused children lead to in the tab n before the selected view's tab, cyclically."
  (%switch-tab! 'layout-tabs:previous-tab n -1))

;; The view selected last in a tab is the one its focused children lead
;; to, so selecting the tab's part-view returns the user to where they were.
(commands:define-command (recent-tab [n (commands:prefix-number)])
  "Selects the view the focused children lead to in the tab used n-th most recently before the selected view's tab."
  (unless (and (integer? n) (exact? n) (> n 0))
    (assertion-violation 'layout-tabs:recent-tab "not a positive exact integer" n))
  (let-values ([(tabs tab) (%selected-tabs 'layout-tabs:recent-tab)])
    (let* ([others (remp (lambda (c) (same-part? c tab)) (parts tabs))]
           [used (fold-left
                   (lambda (acc v)
                     (let* ([atom (layout:view-node v)]
                            [holding (and atom
                                          (find (lambda (c)
                                                  (and (fx<= (document:node-start c) (document:node-start atom))
                                                       (fx<= (document:node-end atom) (document:node-end c))))
                                                others))])
                       (if (and holding (not (memq holding acc))) (cons holding acc) acc)))
                   '() (layout:selection-order))]
           [stops (remp leads-to-locked? (reverse used))])
      (when (> n (length stops))
        (error 'layout-tabs:recent-tab "no more recent tabs"))
      (layout:select! (layout:part-view (list-ref stops (- n 1)))))))

(define (%clicked-tab who event)
  (unless (keys:event? event)
    (assertion-violation who "not an event" event))
  (let* ([posn (keys:event-start event)] [v (views:posn-view posn)] [child (views:posn-node posn)])
    (and v child (eq? (views:buffer v) layout:buffer)
         (let-values ([(tabs tab) (holding-tabs (document:node-start child) (%kind))])
           (and tab (same-part? tab child) tab)))))

(commands:define-command (mouse-select-tab [event (keys:command-event)])
  "Selects the view the focused children lead to in the tab clicked, unless it is locked."
  (let ([tab (%clicked-tab 'layout-tabs:mouse-select-tab event)])
    (when tab
      (let ([target (layout:part-view tab)])
        (unless (layout:locked? (layout:view-node target))
          (layout:select! target))))))

;; A lock binds the user's commands, so a tab holding a locked part stays.
(commands:define-command (mouse-close-tab [event (keys:command-event)])
  "Deletes the tab clicked, with every part in it, unless it holds a locked part."
  (let ([tab (%clicked-tab 'layout-tabs:mouse-close-tab event)])
    (when (and tab (not (holds-locked? tab)))
      (layout:delete-part! tab))))

(commands:define-command (wrap-in-tabs)
  "Wraps the selected part in tabs."
  (layout:wrap! (lambda (parts) (apply container '() parts))))

(keys:bind! keys:global "C-x t 2" new-tab)
(keys:bind! keys:global "C-x t 0" close-tab)
(keys:bind! keys:global "C-x t 1" close-other-tabs)
(keys:bind! keys:global "C-x t o" next-tab)
(keys:bind! keys:global "C-x t O" previous-tab)
(keys:bind! keymap "<down-mouse-1>" mouse-select-tab)
(keys:bind! keymap "<mouse-1>" keys:ignore)
(keys:bind! keymap "<mouse-2>" mouse-close-tab)
(keys:bind! close-keymap "<down-mouse-1>" keys:ignore)
(keys:bind! close-keymap "<mouse-1>" mouse-close-tab)
(keys:bind! layout:part-mode-keymap "w t" wrap-in-tabs)
(tables:set! web:stylesheets 'layout-tabs "layout-tabs/layout-tabs.css")
