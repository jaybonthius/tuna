#!tuna
(import (outline) (status-line) (jump-history) (views) (layout) (commands) (keys) (options) (tables) (haml))

(options:define-option depth #f (lambda (v) (or (not v) (and (fixnum? v) (fx> v 0))))
  "How many of the innermost entries holding point breadcrumb:path shows; #f for all.")

(tables:define-table keymap
  "Clicks on breadcrumb:path, which act on the innermost entry holding point in the view clicked.")

(define (%shown path)
  (let ([n (depth)] [k (length path)])
    (if (and n (fx< n k)) (list-tail path (fx- k n)) path)))

(define (show-path view)
  (unless (views:view? view) (assertion-violation 'breadcrumb:show-path "not a view" view))
  (let* ([b (views:buffer view)] [o (and b (outline:cached b))] [path (and o (outline:path o (views:point view)))])
    (and path (pair? path)
         (let* ([shown (%shown path)] [leaf (car (last-pair shown))])
           (haml (:span ([title (string-append "mouse-1: go to " (outline:entry-name leaf))])
                   (apply append (map (lambda (e) (list (outline:entry-name e) " > ")) (list-head shown (fx- (length shown) 1))))
                   (:span.breadcrumb-leaf (outline:entry-name leaf))))))))

(define (%clicked-view event)
  (let ([node (views:posn-node (keys:event-end event))])
    (and node (layout:part-view node))))

(define (%go! event place)
  (let ([view (%clicked-view event)])
    (when view
      (let* ([b (views:buffer view)] [o (and b (outline:cached b))] [path (and o (outline:path o (views:point view)))])
        (when (and path (pair? path))
          (let ([at (outline:map o (place (car (last-pair path))))] [left (views:point view)])
            (when at
              (layout:select! view)
              (views:set-point! view at)
              (jump-history:push! b left view)
              (jump-history:after-jump view))))))))

(commands:define-command (go-to-entry [event (keys:command-event)])
  "Moves point, in the view whose breadcrumb was clicked, to the name of the innermost entry holding it, recording the place left in jump-history."
  (%go! event outline:entry-point))

(commands:define-command (go-to-entry-end [event (keys:command-event)])
  "Moves point, in the view whose breadcrumb was clicked, to the end of the innermost entry holding it, recording the place left in jump-history."
  (%go! event outline:entry-end))

(status-line:define-segment path
  (show show-path)
  (keymap keymap))

(keys:bind! keymap "<mouse-1>" go-to-entry)
(keys:bind! keymap "<mouse-3>" go-to-entry-end)
(keys:bind! keymap "<down-mouse-1>" keys:ignore)
(keys:bind! keymap "<drag-mouse-1>" keys:ignore)
