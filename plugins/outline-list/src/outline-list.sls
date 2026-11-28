#!tuna
(import (outline) (ui) (jump-history) (pulse) (buffers) (document) (views) (layout) (modes) (commands) (keys) (hooks)
        (options) (tables) (haml))

(tables:define-table keymap "Keys in outline lists.")

(tables:define-table name-keymap "Keys on an entry's name, for clicks.")

(hooks:define-hook mode-hook "Called in each outline list as its mode is set.")

(modes:define-major-mode mode
  (parent ui:section-mode)
  (lighter "Outline")
  (keymap keymap)
  (hook mode-hook)
  (plugin-only #t))

(options:define-option follow? #f boolean?
  "Whether the selected row of an outline list follows point in the buffer it lists.")

(buffers:define-kind %contents (content nodes))

(define (%draw-name node view)
  (haml (:span ([data-kind (document:node-attribute node 'kind)] [data-face (document:node-attribute node 'face #f)]
                [data-keymap (views:keymap-mark name-keymap)])
          (views:draw-children view node))))

(buffers:define-kind %name (inline) (draw %draw-name))

(define-record-type %list
  (sealed #t)
  (fields listed (mutable outline) (mutable entries) (mutable identities)))

(define %lists (make-weak-eq-hashtable))

(define (%name-datum e)
  (let* ([kind (outline:entry-kind e)] [k (tables:ref outline:kinds kind #f)])
    (%name (append (list (cons 'kind (symbol->string kind)))
                   (if k (list (cons 'face (symbol->string (outline:kind-face k)))) '()))
           (outline:entry-name e))))

(define (%datums o)
  (let ([paths (outline:paths o)])
    (define (section e)
      (apply ui:section `((type . entry) (value . ,(eq-hashtable-ref paths e #f))) (list (%name-datum e))
             (map section (outline:entry-children e))))
    (map section (outline:roots o))))

(define (%take! l o)
  (let ([paths (outline:paths o)] [entries (make-hashtable string-hash string=?)] [identities (make-eq-hashtable)])
    (let loop ([es (outline:roots o)] [identity '()])
      (for-each (lambda (e)
                  (let* ([value (eq-hashtable-ref paths e #f)] [identity (cons (cons 'entry value) identity)])
                    (hashtable-set! entries value e)
                    (eq-hashtable-set! identities e identity)
                    (loop (outline:entry-children e) identity)))
                es))
    (%list-outline-set! l o)
    (%list-entries-set! l entries)
    (%list-identities-set! l identities)))

;; outline makes again only an outline read since it was last made, so a
;; list that read only at a change would stop following its buffer after
;; a remake that changes nothing.
(define (%read! l)
  (let ([o (outline:cached (%list-listed l))])
    (unless (or (not o) (eq? o (%list-outline l))) (%take! l o))
    (%list-outline l)))

(define (%views-of lb) (filter (lambda (v) (eq? (views:buffer v) lb)) (layout:views)))

(define (%select-entry! lb view e)
  (let* ([l (eq-hashtable-ref %lists lb #f)] [identity (eq-hashtable-ref (%list-identities l) e #f)]
         [section (and identity (ui:find-section lb identity))])
    (when section (views:set-point! view (ui:section-heading-start section)))))

(define (%select-entry-at! lb view position)
  (let* ([l (eq-hashtable-ref %lists lb #f)] [o (%list-outline l)] [path (and o (outline:path o position))])
    (when (and path (pair? path))
      (%select-entry! lb view (car (last-pair path))))))

(define (%fill! lb)
  (let* ([l (eq-hashtable-ref %lists lb #f)] [o (outline:cached (%list-listed l))]
         [selected (map (lambda (v) (let ([s (ui:section-at v)]) (cons v (and s (ui:section-identity s lb)))))
                        (%views-of lb))])
    (when o
      (%take! l o)
      (buffers:reconcile! lb (document:token (buffers:document lb) 0) (%datums o)))
    (for-each (lambda (vs)
                (let ([section (and (cdr vs) (ui:find-section lb (cdr vs)))])
                  (when section (views:set-point! (car vs) (ui:section-heading-start section)))))
              selected)))

(define (%list-buffer b)
  (or (exists (lambda (lb) (and (buffers:live? lb) (eq? (%list-listed (eq-hashtable-ref %lists lb #f)) b) lb))
              (vector->list (hashtable-keys %lists)))
      (let ([lb (buffers:make (buffers:free-name (string-append "*Outline " (buffers:name b) "*")) (%contents '()))])
        (buffers:set-silent! lb #t)
        (eq-hashtable-set! %lists lb (make-%list b #f (make-hashtable string-hash string=?) (make-eq-hashtable)))
        (modes:set-major-mode mode lb)
        lb)))

(commands:define-command (show)
  "Shows the current buffer's outline in a list in another view and selects it, with the row of the entry holding point selected."
  (let ([view (layout:selected-view)])
    (unless (outline:get (views:buffer view)) (error 'outline-list:show "This buffer has no outline"))
    (let ([lb (%list-buffer (views:buffer view))])
      (%fill! lb)
      (let ([list-view (layout:display-buffer lb layout:display-in-other-view)])
        (layout:select! list-view)
        (%select-entry-at! lb list-view (views:point view))))))

(define (%selected who)
  (let* ([view (views:current)] [lb (views:buffer view)] [l (eq-hashtable-ref %lists lb #f)]
         [section (and l (%read! l) (ui:section-at view))]
         [e (and section (hashtable-ref (%list-entries l) (ui:section-value section) #f))])
    (unless e (error who "Nothing at point"))
    (values l view e)))

;; jump-history:push! records in the selected view's history, so the
;; place is recorded once the view it was left in is selected, and
;; selected again when the list stays.
(define (%go! who stay? record?)
  (let-values ([(l list-view e) (%selected who)])
    (let* ([b (%list-listed l)] [at (and (buffers:live? b) (outline:map (%list-outline l) (outline:entry-point e)))])
      (unless at (error who "The listed buffer changed too much since its outline was made; press g"))
      (let* ([view (layout:display-buffer b layout:display-in-other-view)] [left (views:point view)])
        (views:set-point! view at)
        (cond
          [record?
           (layout:select! view)
           (jump-history:push! b left view)
           (jump-history:after-jump view)
           (when stay? (layout:select! list-view))]
          [else (pulse:highlight-line! view)])
        (values view list-view)))))

(commands:define-command (go-to-entry)
  "Goes to the selected row's entry in the view showing the listed buffer, or another view, recording the place left in jump-history."
  (%go! 'outline-list:go-to-entry #f #t))

(commands:define-command (mouse-go-to-entry [event (keys:command-event)])
  "Selects the row clicked and goes to its entry, as outline-list:go-to-entry does."
  (unless (keys:event? event)
    (assertion-violation 'outline-list:mouse-go-to-entry "not a mouse event" event))
  (let* ([posn (keys:event-end event)] [view (views:posn-view posn)] [p (views:posn-point posn)])
    (unless (and view p (eq-hashtable-ref %lists (views:buffer view) #f))
      (error 'outline-list:mouse-go-to-entry "Nothing at point"))
    (layout:select! view)
    (views:set-point! view p)
    (%go! 'outline-list:mouse-go-to-entry #f #t)))

(commands:define-command (show-entry)
  "Goes to the selected row's entry as outline-list:go-to-entry does, leaving the list's view selected."
  (%go! 'outline-list:show-entry #t #t))

(commands:define-command (next-entry [n (commands:prefix-number)])
  "Selects the row N after the selected one and shows its entry in the view of the listed buffer."
  (ui:section-forward n)
  (%go! 'outline-list:next-entry #t #f))

(commands:define-command (previous-entry [n (commands:prefix-number)])
  "Selects the row N before the selected one and shows its entry in the view of the listed buffer."
  (ui:section-backward n)
  (%go! 'outline-list:previous-entry #t #f))

(commands:define-command (visit-and-quit)
  "Goes to the selected row's entry as outline-list:go-to-entry does, then quits the list's view."
  (let-values ([(view list-view) (%go! 'outline-list:visit-and-quit #f #t)])
    (layout:select! list-view)
    (layout:quit-view)
    (layout:select! view)))

(commands:define-command (refresh)
  "Forgets the listed buffer's outline and makes the list again from a new one."
  (let* ([lb (views:buffer (views:current))] [l (eq-hashtable-ref %lists lb #f)])
    (unless l (error 'outline-list:refresh "Not an outline list"))
    (let ([b (%list-listed l)])
      (outline:forget! b)
      (unless (outline:get b) (error 'outline-list:refresh "This buffer has no outline"))
      (%fill! lb))))

(define (%updated b o)
  (vector-for-each
    (lambda (lb)
      (when (and (buffers:live? lb) (eq? (%list-listed (eq-hashtable-ref %lists lb #f)) b))
        (%fill! lb)))
    (hashtable-keys %lists)))

(define (%after-command command)
  (let* ([view (layout:selected-view)] [b (and view (views:buffer view))])
    (vector-for-each
      (lambda (lb)
        (let ([l (eq-hashtable-ref %lists lb #f)] [shown (%views-of lb)])
          (when (and (buffers:live? lb) (pair? shown) (buffers:live? (%list-listed l)))
            (%read! l)
            (when (and (follow?) (eq? (%list-listed l) b))
              (for-each (lambda (v) (%select-entry-at! lb v (views:point view))) shown)))))
      (hashtable-keys %lists))))

(keys:bind! keymap "RET" go-to-entry)
(keys:bind! keymap "SPC" show-entry)
(keys:bind! keymap "M-RET" visit-and-quit)
(keys:bind! keymap "n" next-entry)
(keys:bind! keymap "p" previous-entry)
(keys:bind! keymap "g" refresh)
(keys:bind! name-keymap "<mouse-1>" mouse-go-to-entry)
(keys:bind! name-keymap "<mouse-2>" mouse-go-to-entry)
(keys:bind! name-keymap "<down-mouse-1>" keys:ignore)
(keys:bind! name-keymap "<drag-mouse-1>" keys:ignore)
(hooks:add! outline:updated %updated)
(hooks:add! commands:after-command %after-command)
