(import (tuna) (test) (test-runner) (test-user) (modes) (buffers) (document) (views) (layout) (layout-split) (hooks) (options)
        (tables) (web) (syntax) (syntax-highlighting) (chez-scheme) (rainbow-delimiters) (layout-test parts)
        (chez-scheme-test scheme-buffers) (buffers-test))

(define (turn-on) (options:set-local! rainbow-delimiters:mode #t))

(hooks:add! chez-scheme:mode-hook turn-on)

(define (depths b) (map (lambda (s) (cdr (assq 'bracket (caddr s)))) (chez-scheme-test/scheme-buffers:brackets b)))

(define (depths-become b expected) (test-runner:wait-until (lambda () (equal? expected (depths b)))))

(define (faces view)
  (test-user:settle)
  (fold-right
    (lambda (e acc)
      (let ([face (test-user:element-attribute e "data-face")])
        (if (and (> (string-length face) 19) (string=? "rainbow-delimiters." (substring face 0 19)))
            (cons (string->symbol (substring face 19 (string-length face))) acc)
            acc)))
    '()
    (test-user:elements-with (layout-test/parts:view-element view) "data-face")))

(define (show! b) (views:set-buffer! (layout:selected-view) b) b)

(test "the mode is off by default; a configuration's hook entry turns it on in Scheme buffers, which then use brackets"
  (let ([plain (buffers:make "notes.txt" "(a)")] [b (chez-scheme-test/scheme-buffers:scheme-buffer "a.ss" "(a)\n")])
    (check-equal? '(#f #f #f) (list (rainbow-delimiters:mode) (buffers:with-buffer plain (rainbow-delimiters:mode)) (syntax:brackets-used? plain)))
    (check-equal? '(#t #t) (list (buffers:with-buffer b (rainbow-delimiters:mode)) (syntax:brackets-used? b)))))

(test "a minor mode defined with the form, with no keymap and no lighter, on in the views of its buffers"
  (let ([b (show! (chez-scheme-test/scheme-buffers:scheme-buffer "on.ss" "(a)\n"))])
    (check-equal? '(rainbow-delimiters:mode 0 #f #f)
                  (list (modes:name rainbow-delimiters:mode) (tables:ref modes:minor-modes rainbow-delimiters:mode #f)
                        (tables:ref modes:keymaps rainbow-delimiters:mode #f) (modes:lighter rainbow-delimiters:mode)))
    (check (memq rainbow-delimiters:mode (modes:active-minor-modes (layout:selected-view))))))

(define nested "(define (f x) [list #(x)])\n")

(test "the job sends a span per bracket with its depth, and each is drawn with the face of its depth"
  (let ([b (show! (chez-scheme-test/scheme-buffers:scheme-buffer "nested.ss" nested))])
    (depths-become b '(1 2 2 2 3 3 2 1))
    (check-equal? '((1 2) (9 10) (13 14) (15 16) (21 23) (24 25) (25 26) (26 27))
                  (map (lambda (s) (list (car s) (cadr s))) (chez-scheme-test/scheme-buffers:brackets b)))
    (check-equal? '(depth-1 depth-2 depth-2 depth-2 depth-3 depth-3 depth-2 depth-1) (faces (layout:selected-view)))))

(define deep-text "((((((((((((x))))))))))))\n) (]\n")

(test "depths 1 to 9 have a face each, deeper ones take them again in turn; an unopened closing bracket is unmatched, a wrong shape mismatched"
  (let ([deep (show! (chez-scheme-test/scheme-buffers:scheme-buffer "deep.ss" deep-text))])
    (depths-become deep '(1 2 3 4 5 6 7 8 9 10 11 12 12 11 10 9 8 7 6 5 4 3 2 1 unmatched 1 mismatched))
    (check-equal? '(depth-1 depth-2 depth-3 depth-4 depth-5 depth-6 depth-7 depth-8 depth-9 depth-1 depth-2 depth-3 depth-3 depth-2 depth-1
                    depth-9 depth-8 depth-7 depth-6 depth-5 depth-4 depth-3 depth-2 depth-1 unmatched depth-1 mismatched)
                  (faces (layout:selected-view)))))

(test "with one outermost-only face, the faces past depth 9 start again at depth-2; the count is from 0 to 8"
  (depths-become (show! (chez-scheme-test/scheme-buffers:scheme-buffer "deep.ss" deep-text))
                 '(1 2 3 4 5 6 7 8 9 10 11 12 12 11 10 9 8 7 6 5 4 3 2 1 unmatched 1 mismatched))
  (options:set! rainbow-delimiters:outermost-only-face-count 1)
  (check-equal? '(depth-1 depth-2 depth-3 depth-4 depth-5 depth-6 depth-7 depth-8 depth-9 depth-2 depth-3 depth-4 depth-4 depth-3 depth-2
                  depth-9 depth-8 depth-7 depth-6 depth-5 depth-4 depth-3 depth-2 depth-1 unmatched depth-1 mismatched)
                (faces (layout:selected-view)))
  (options:unset! rainbow-delimiters:outermost-only-face-count)
  (check-raises assertion-violation? (options:set! rainbow-delimiters:outermost-only-face-count 9))
  (check-raises assertion-violation? (options:set! rainbow-delimiters:outermost-only-face-count -1)))

(test "a view's own value turns the colours off in that view only; turning them on there takes the buffer's value"
  (let* ([b (show! (chez-scheme-test/scheme-buffers:scheme-buffer "views.ss" nested))]
         [v (layout:selected-view)]
         [w (layout-split:split-view! v (layout-split:direction row))])
    (views:set-buffer! w b)
    (depths-become b '(1 2 2 2 3 3 2 1))
    (views:set-option! v rainbow-delimiters:mode #f)
    (check-equal? '(() (depth-1 depth-2 depth-2 depth-2 depth-3 depth-3 depth-2 depth-1)) (list (faces v) (faces w)))
    (views:set-option! v rainbow-delimiters:mode #t)
    (check-equal? '(depth-1 depth-2 depth-2 depth-2 depth-3 depth-3 depth-2 depth-1) (faces v))
    (buffers:with-buffer b (options:set-local! rainbow-delimiters:mode #f))
    (check-equal? #f (syntax:brackets-used? b))
    (depths-become b '())
    (check-equal? '() (faces v))
    (buffers:with-buffer b (options:set-local! rainbow-delimiters:mode #t))
    (depths-become b '(1 2 2 2 3 3 2 1))
    (check-equal? '(depth-1 depth-2 depth-2 depth-2 depth-3 depth-3 depth-2 depth-1) (faces v))
    (views:remove-option! v rainbow-delimiters:mode)
    (layout:delete-part! (layout:view-node w))))

(tables:define-table data-keymap "Keys.")

(hooks:define-hook data-hook "Setup.")

(modes:define-major-mode data-mode (keymap data-keymap) (hook data-hook))

(test "a mode with a lexer and no highlighting job gets no bracket spans, so no colours"
  (tables:set! syntax:lexers data-mode chez-scheme:lexer)
  (let ([data (buffers:make "data" "(a (b))")])
    (modes:set-major-mode data-mode data)
    (buffers:with-buffer data (options:set-local! rainbow-delimiters:mode #t))
    (check-equal? #t (syntax:brackets-used? data))
    (syntax-highlighting:update!)
    (test-user:settle)
    (check-equal? '() (depths data))))

(test "the stylesheet is in web:stylesheets under rainbow-delimiters"
  (check-equal? "rainbow-delimiters/rainbow-delimiters.css" (tables:ref web:stylesheets 'rainbow-delimiters #f)))

(test "a command in a view whose own value is #f takes every buffer's bracket spans away, until the jobs read their inputs outside such a command"
  (let* ([b (show! (chez-scheme-test/scheme-buffers:scheme-buffer "b.ss" nested))] [v (layout:selected-view)] [c (buffers:make "c.ss" "(x (y))\n")])
    (depths-become b '(1 2 2 2 3 3 2 1))
    (views:set-option! v rainbow-delimiters:mode #f)
    (check-equal? #f (views:call-with-view v (lambda () (syntax:brackets-used? b))))
    (views:call-with-view v (lambda () (modes:set-major-mode chez-scheme:mode c)))
    (check-equal? #t (buffers:with-buffer c (rainbow-delimiters:mode)))
    (depths-become c '(1 2 2 1))
    (depths-become b '())
    (views:remove-option! v rainbow-delimiters:mode)
    (syntax-highlighting:update!)
    (depths-become b '(1 2 2 2 3 3 2 1))
    (depths-become c '(1 2 2 1))))

(test "unloading takes away the entry and the stylesheet and stops the bracket spans, a hook entry naming the mode is skipped without a report, and loading again brings them back"
  (let ([b (chez-scheme-test/scheme-buffers:scheme-buffer "unload.ss" nested)])
    (depths-become b '(1 2 2 2 3 3 2 1))
    (unload-owner! (module-owner '(rainbow-delimiters)))
    (check-equal? '(#f #f) (list (tables:ref syntax:bracket-users 'rainbow-delimiters #f) (tables:ref web:stylesheets 'rainbow-delimiters #f)))
    (depths-become b '())
    (buffers:replace! b 1 1 "(x) ")
    (test-user:settle)
    (check-equal? '() (depths b))
    (check-equal? '() (buffers-test:reports-during (lambda () (chez-scheme-test/scheme-buffers:scheme-buffer "z.ss" "(q)\n"))))
    (load-module! '(rainbow-delimiters))
    (depths-become b '(1 1 1 2 2 2 3 3 2 1))))
