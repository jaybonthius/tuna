#!tuna
(import (layout) (buffers) (document) (views) (keys) (commands) (web) (haml))

(module %internals
  (parts tabs-node? holding-tabs place-attribute?)

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

  ;; What a view atom says of itself stays with it; the rest describes its
  ;; place, which the tabs container wrapping it takes.
  (define (place-attribute? a) (not (memq (car a) '(view buffer title)))))

(import %internals)

(define (%draw-tabs node children focused draw-child client)
  (let ([shown (or (and focused
                        (find (lambda (c) (fx= (document:node-start c) (document:node-start focused))) children))
                   (car children))])
    (haml (:div.tabs ([class (layout:part-class node)])
            (:div.tabs-strip ([role "tablist"])
              (map (lambda (c)
                     (haml (:div.tab ([role "tab"] [aria-selected (if (eq? c shown) "true" "false")]
                                      [data-at (document:node-start c)] [data-to (document:node-end c)])
                             (layout:part-title c))))
                   children))
            (:div.tabs-panel ([role "tabpanel"]) (draw-child shown))))))

(define-table keymap "The keymap of tabs containers, for clicks on their labels.")

(layout:define-container container
  (draw %draw-tabs)
  (keymap keymap)
  (show-focused))

(define (%kind) (car (container '())))

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
    (let* ([at (document:node-start tab)]
           [stops (filter (lambda (c)
                            (or (fx= (document:node-start c) at)
                                (not (layout:locked? (layout:view-node (layout:part-view c))))))
                          (parts tabs))]
           [k (let loop ([cs stops] [k 0]) (if (fx= (document:node-start (car cs)) at) k (loop (cdr cs) (fx+ k 1))))])
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

(commands:define-command (next-tab [n (commands:prefix-number)])
  "Selects the view the focused children lead to in the tab n after the selected view's tab, cyclically."
  (%switch-tab! 'layout-tabs:next-tab n 1))

(commands:define-command (previous-tab [n (commands:prefix-number)])
  "Selects the view the focused children lead to in the tab n before the selected view's tab, cyclically."
  (%switch-tab! 'layout-tabs:previous-tab n -1))

;; views places a click on a label of a container one past the
;; container's start, where its first child may start too, so a click
;; there is taken for the label and the tab's own focused children decide
;; the view; a click deeper in the tab is layout's.
(commands:define-command (mouse-select-tab [event (keys:command-event)])
  "Selects the view the focused children lead to in the tab whose label was clicked, unless it is locked."
  (unless (keys:event? event)
    (assertion-violation 'layout-tabs:mouse-select-tab "not an event" event))
  (let* ([posn (keys:event-start event)] [v (views:posn-view posn)] [p (views:posn-point posn)])
    (when (and v p (eq? (views:buffer v) layout:buffer))
      (let-values ([(tabs tab) (holding-tabs p (%kind))])
        (cond
          [(not tab) (void)]
          [(fx<= p (fx+ (document:node-start tab) 1))
           (let ([target (layout:part-view tab)])
             (unless (layout:locked? (layout:view-node target))
               (layout:select! target)))]
          [else (layout:mouse-select-view event)])))))

(commands:define-command (wrap-in-tabs)
  "Wraps the selected part in tabs."
  (layout:wrap! (lambda (parts) (apply container '() parts))))

(keys:bind! keys:global "C-x t 2" new-tab)
(keys:bind! keys:global "C-x t 0" close-tab)
(keys:bind! keys:global "C-x t o" next-tab)
(keys:bind! keys:global "C-x t O" previous-tab)
(keys:bind! keymap "<mouse-1>" mouse-select-tab)
(keys:bind! layout:part-mode-keymap "w t" wrap-in-tabs)
(table-set! web:stylesheets 'layout-tabs "layout-tabs/layout-tabs.css")
