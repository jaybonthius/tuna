(import (tuna) (test))

;; A form of its own, so it loads before echo-area.
(import (echo-area-test beneath))

(import (test-user) (layout) (layout-split) (views) (buffers) (keys) (echo-area) (echo-area-test))

(define (place b depth) ((layout-split:display-at-side (layout:direction down) depth 'content '((locked . #t))) b))

(define (bottom-names) (map (lambda (attributes) (cdr (assq 'buffer attributes))) (echo-area-test:bottom-parts)))

(test "the echo area sits at the bottom at its content's height, locked, at depth 90, outside the level of the user's windows"
  (let ([attributes (car (echo-area-test:bottom-parts))])
    (check-equal? '(" *Echo Area*" 90 content #t)
      (map (lambda (key) (cdr (assq key attributes))) '(buffer depth size locked))))
  (check (layout:locked? (layout:view-node (echo-area-test:echo-view))))
  (check (buffers:silent? layout:buffer)))

(test "parts placed at the bottom are ordered by depth, then in the order placed, and placing the echo area again finds its view"
  (let ([prompt (buffers:make " *Minibuf*" "")] [notice (buffers:make "*notice*" "")] [late (buffers:make "*late*" "")])
    (place prompt 100)
    (place notice 95)
    (place late 90)
    (check-equal? '(" *Echo Area*" "*late*" "*notice*" " *Minibuf*") (bottom-names))
    (check (eq? (echo-area-test:echo-view) (place (echo-area-test:echo-buffer) 10)))
    (for-each (lambda (b) (layout:delete-part! (layout:view-node (layout:find-view b)))) (list prompt notice late))
    (check-equal? '(" *Echo Area*") (bottom-names))))

(test "the echo area's buffer is internal, and other-view passes over its locked view"
  (check (buffers:internal-name? (buffers:name (echo-area-test:echo-buffer))))
  (test-user:press! "C-x o")
  (check (not (eq? (echo-area-test:view) (echo-area-test:echo-view)))))
