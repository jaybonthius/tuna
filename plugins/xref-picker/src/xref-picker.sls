#!tuna
(import (xref) (jump-history) (completion) (files) (projects) (buffers) (document) (views) (layout) (commands) (keys) (faces) (options) (tables)
        (timers) (saved))

(define %self (current-owner))

(define (%project-root)
  (let ([project (projects:find (files:directory))])
    (and project (projects:root project))))

(define (%path-text path root)
  (if (and root (fx> (string-length path) (string-length root)) (string=? (substring path 0 (string-length root)) root))
      (substring path (string-length root) (string-length path))
      (files:abbreviated-path path)))

(saved:define-saved xref-history '() (lambda (v) (and (list? v) (for-all string? v))))

(saved:define-saved symbol-history '() (lambda (v) (and (list? v) (for-all string? v))))

(options:define-option preview-delay 0 (lambda (v) (and (real? v) (>= v 0)))
  "Seconds an item must stay selected before xref-picker:choose-and-go shows its place.")

(define (%location item) (cons* (xref:item-path item) (xref:item-line item) (xref:item-column item)))

(define (choose-and-go items title)
  (unless (and (pair? items) (for-all xref:item? items))
    (assertion-violation 'xref-picker:choose-and-go "not a list of items" items))
  (if (null? (cdr items))
      (xref:go-to-item (car items))
      (let* ([root (%project-root)] [by-location (map (lambda (item) (cons (%location item) item)) items)]
             [location
              (layout:call-with-display-view
                (lambda (display-view)
                  (let-values ([(show end) (completion:location-preview display-view jump-history:after-jump)])
                    (completion:read (string-append title ": ")
                      (list (completion:source
                              (candidates
                                (list->vector
                                  (map (lambda (item)
                                         (cons (format "~a:~a: ~a" (%path-text (xref:item-path item) root) (xref:item-line item)
                                                       (xref:item-summary item))
                                               (%location item)))
                                       items)))
                              (in-order)
                              (group (lambda (text location) (%path-text (car location) root))
                                     (lambda (text location)
                                       (let ([n (string-length (%path-text (car location) root))])
                                         (substring text (fx+ n 1) (string-length text)))))
                              (category completion:location-category)
                              (preview show end)
                              (preview-delay (preview-delay))))
                      xref-history))))])
        (xref:go-to-item (cdr (assoc location by-location))))))

(completion:define-category symbol-category "Identifiers a backend's apropos found, valued by the item.")

(define (%symbol-annotator session)
  (lambda (item details)
    (append (list (cons faces:shadow (format "~a:~a" (files:abbreviated-path (xref:item-path item)) (xref:item-line item))))
            (if (xref:item-kind item) (list (cons faces:shadow (xref:item-kind item))) '()))))

(define (%apropos-source apropos)
  (lambda (emit)
    (let ([asked #f] [timer #f] [task #f])
      (define (stop!)
        (when timer
          (timers:cancel! timer)
          (set! timer #f))
        (when (and task (not (eq? (task-state task) 'done)))
          (cancel-task task))
        (set! task #f))
      (define (ask! input)
        (set! task
          (spawn-task
            (lambda (restore)
              (let ([items (guard (c [(cancelled? c) #f] [else (report c) '()]) (apropos input))])
                (when items
                  (emit 'clear)
                  (emit (list->vector (map (lambda (item) (cons (xref:item-summary item) item)) items)))
                  (emit 'done)))))))
      (lambda (input)
        (cond
          [(eof-object? input) (stop!)]
          [(equal? input asked) (unless (or timer task) (emit 'done))]
          [else
           (stop!)
           (set! asked input)
           (if (fx< (string-length input) (completion:async-min-input))
               (begin (emit 'clear) (emit 'done))
               (set! timer
                 (call-as-owner %self
                   (lambda ()
                     (timers:run-after (completion:async-delay)
                       (lambda ()
                         (set! timer #f)
                         (ask! input)))))))])))))

(define (%quit) (make-cancelled #f))

(define (%read-apropos-item)
  (let ([view (views:current)])
    (completion:read-with-input-history "Search for symbols: "
      (list (completion:source
              (stream (%apropos-source (lambda (pattern) (xref:apropos view pattern))))
              (own-matching)
              (in-order)
              (category symbol-category)))
      symbol-history)))

(commands:define-command (find-apropos [item (%read-apropos-item)])
  "Goes to ITEM, read from the backend's apropos as the input is typed, and records the place point left in jump-history."
  (let* ([view (layout:selected-view)] [left (views:buffer view)] [at (views:point view)])
    (xref:go-to-item item)
    (jump-history:push! left at)))

(options:set! xref:definitions-display choose-and-go xref:references-display choose-and-go)
(tables:set! completion:annotators symbol-category %symbol-annotator)
(keys:remap! keys:global xref:find-apropos find-apropos)
