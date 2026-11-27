#!tuna
(import (syntax) (syntax-highlighting) (buffers) (views) (modes) (web) (options) (tables))

(modes:define-minor-mode mode
  "Whether brackets are coloured by depth."
  (on-change (lambda (on?) (syntax-highlighting:update!))))

(options:define-option outermost-only-face-count 0 (lambda (v) (and (fixnum? v) (fx<= 0 v 8)))
  "How many of the outermost depths keep their face for themselves: past depth 9 the faces start again after them.")

(define (%bracket-face bracket)
  (cond
    [(eq? bracket 'unmatched) "rainbow-delimiters.unmatched"]
    [(eq? bracket 'mismatched) "rainbow-delimiters.mismatched"]
    [(and (fixnum? bracket) (fx> bracket 0))
     (string-append "rainbow-delimiters.depth-"
       (number->string
         (if (fx<= bracket 9)
             bracket
             (let ([kept (outermost-only-face-count)])
               (fx+ 1 kept (fxmod (fx- bracket 10) (fx- 9 kept)))))))]
    [else #f]))

(define (%bracket-attributes bracket)
  (let ([face (and (mode) (%bracket-face bracket))])
    (if face (list (cons "data-face" face)) '())))

(define (%draws-brackets? buffer)
  (buffers:with-buffer buffer (mode)))

(tables:set! syntax:bracket-users 'rainbow-delimiters %draws-brackets?)
(tables:set! views:span-properties 'bracket %bracket-attributes)
(tables:set! web:stylesheets 'rainbow-delimiters "rainbow-delimiters/rainbow-delimiters.css")
(syntax-highlighting:update!)
;; The plugin's table entries are out of effect from the start of its
;; unload, and nothing tells the highlighters that their inputs changed.
(on-unload syntax-highlighting:update!)
