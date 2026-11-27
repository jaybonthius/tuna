(import (tuna) (test) (test-runner) (tables) (buffers) (document) (modes) (syntax-highlighting) (chez-scheme))

(define (car-face b)
  (let ([spans (buffers:spans (buffers:layer b syntax-highlighting:faces) 0 (document:length (buffers:document b)))])
    (and (pair? spans) (cdr (assq 'face (caddr (car spans)))))))

(define user (buffers:make "user.ss" "(car 1)"))

(modes:set-major-mode chez-scheme:mode user)

(define old (module-owner '(chez-scheme)))

(test "unloading the plugin stops every job and takes its spans away"
  (test-runner:wait-until (lambda () (eq? 'function.builtin (car-face user))))
  (unload-owner! old)
  (check (not (owner-live? old)))
  (test-runner:wait-until (lambda () (not (car-face user)))))

;; A form's names are found when the form is evaluated, so the module
;; loads again before the form that uses it.
(load-module! '(chez-scheme))

(test "a new instance highlights the buffers already open in its mode"
  (check (syntax-highlighting:highlighter? (tables:ref syntax-highlighting:highlighters chez-scheme:mode #f)))
  (test-runner:wait-until (lambda () (eq? 'function.builtin (car-face user)))))
