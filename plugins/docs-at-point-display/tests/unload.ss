(import (tuna) (test) (hooks) (keys) (docs-at-point) (docs-at-point-display))

(define old (module-owner '(docs-at-point-display)))

(test "loaded, it adds its two displays and binds C-h .; its unload takes them back"
  (check-equal? 2 (length (hooks:entries docs-at-point:displays)))
  (check-equal? docs-at-point-display:show-docs (keys:lookup-in (list keys:global) "C-h ."))
  (unload-owner! old)
  (check-equal? '() (hooks:entries docs-at-point:displays))
  (check-equal? #f (keys:lookup-in (list keys:global) "C-h .")))

;; A form's names are found when the form is evaluated, so the module
;; loads again before the form that uses it.
(load-module! '(docs-at-point-display))

(test "a new instance adds its displays again"
  (check (not (eq? old (module-owner '(docs-at-point-display)))))
  (check-equal? 2 (length (hooks:entries docs-at-point:displays))))
