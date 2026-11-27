(import (tuna) (test) (test-browser) (cdp page) (design-tokens) (faces) (views) (layout) (layout-split) (editing)
        (echo-area) (status-line) (minibuffer) (faces-test))

(define page (test-browser:open (page-options [width 1400] [height 1000] [color-scheme (color-scheme light)])))

(define compared
  '("color" "background-color" "font-weight" "font-style" "font-family" "font-size" "text-decoration-line"))

(define (case-looks css)
  (faces-test:set-case! page #f css)
  (faces-test:item-looks (faces-test:snapshot page)))

(faces-test:show-fixture!)

(define base (case-looks ""))

(define (base-style face property) (cdr (assoc property (cdr (assq face base)))))

(define (item-style looks face property) (cdr (assoc property (cdr (assq face looks)))))

(define (changed looks skip)
  (filter (lambda (face)
            (and (not (memq face skip))
                 (exists (lambda (p) (not (equal? (item-style looks face p) (base-style face p)))) compared)))
          (map car looks)))

(define keyword-family (list faces:keyword faces:keyword.return 'keyword.function faces:keyword.directive))

(test "a weight set on a family's token reaches every member, one no plugin defines included, and nothing else"
  (let ([looks (case-looks ":root { --faces-keyword-font-weight: bold; }")])
    (check-equal? '("700" "700" "700" "700") (map (lambda (f) (item-style looks f "font-weight")) keyword-family))
    (check-equal? '() (changed looks keyword-family))))

(test "a member's own token beats its family's"
  (let ([looks (case-looks ":root { --faces-keyword-font-weight: bold; --faces-keyword-return-font-weight: normal; }")])
    (check-equal? '("700" "400" "700")
                  (map (lambda (f) (item-style looks f "font-weight")) (list faces:keyword faces:keyword.return 'keyword.function)))))

(test "each of a face's seven tokens sets its property alone"
  (for-each
    (lambda (token property value)
      (let* ([looks (case-looks (format ":root { --faces-keyword-~a: ~a; }" token value))]
             [others (filter (lambda (p) (not (equal? (item-style looks faces:keyword p) (base-style faces:keyword p))))
                             (remove property compared))])
        (check-equal? (list token value '()) (list token (item-style looks faces:keyword property) others))))
    '("color" "background" "font-weight" "font-style" "font-family" "font-size" "text-decoration")
    '("color" "background-color" "font-weight" "font-style" "font-family" "font-size" "text-decoration-line")
    '("rgb(1, 2, 3)" "rgb(4, 5, 6)" "300" "italic" "serif" "21px" "overline")))

(faces-test:set-case! page #f "")

(test "errors, warnings and successes are bold by default"
  (check-equal? '("700" "700" "700") (map (lambda (f) (base-style f "font-weight")) (list faces:error faces:warning faces:success))))

(test "a keyword in a heading is bold, as keyword sets no weight of its own"
  (let ([shot (faces-test:snapshot page)])
    (check-equal? "700" (faces-test:style shot (faces-test:faced shot "hkw" faces:keyword) "font-weight"))))

(test "in a list of faces the inner face's rules win and the outer face's show where the inner sets none"
  (let* ([shot (faces-test:snapshot page)] [x (faces-test:faced shot "x" faces:markup.strong)] [y (faces-test:faced shot "y" faces:markup.raw)])
    (check-equal? (list "700" (base-style faces:keyword "color")) (list (faces-test:style shot x "font-weight") (faces-test:style shot x "color")))
    (check-equal? (list (base-style faces:markup.raw "color") "Fira Code") (list (faces-test:style shot y "color") (faces-test:family shot y)))))

(test "key-binding draws in the code font and the info colour, on no background"
  (faces-test:set-case! page #f ":root { --tuna-info: rgb(9, 8, 7); }")
  (let* ([shot (faces-test:snapshot page)] [k (faces-test:faced shot "C-x" faces:key-binding)])
    (check-equal? '("Fira Code" "rgb(9, 8, 7)" "rgba(0, 0, 0, 0)")
                  (list (faces-test:family shot k) (faces-test:style shot k "color") (faces-test:style shot k "background-color")))))

;; Text decorations are drawn through every inline element inside the one
;; that sets them, whatever those set, so the diagnostic's line shows on
;; the keyword exactly when an element around it on its line draws one.
(define (word-lines)
  (let* ([shot (faces-test:snapshot page)]
         [word (faces-test:faced shot "word" faces:keyword)]
         [around (let up ([chain (faces-test:ancestors shot word)])
                   (if (or (null? chain) (faces-test:has-class? shot (car chain) "line"))
                       '()
                       (cons (car chain) (up (cdr chain)))))])
    (list (faces-test:style shot word "text-decoration-line")
          (faces-test:style shot word "display")
          (map (lambda (i)
                 (list (faces-test:attribute shot i "data-face")
                       (faces-test:style shot i "text-decoration-line")
                       (faces-test:style shot i "text-decoration-style")
                       (faces-test:style shot i "text-decoration-color")))
               (filter (lambda (i) (not (equal? "none" (faces-test:style shot i "text-decoration-line")))) around)))))

(test "a diagnostic's underline shows under a word whose own face draws no line"
  (faces-test:set-case! page #f
    ":root { --tuna-error: rgb(255, 0, 0); --faces-keyword-color: rgb(0, 0, 0); --faces-keyword-text-decoration: none; }")
  (check-equal? '("none" "inline" (("diagnostic.error" "underline" "wavy" "rgb(255, 0, 0)"))) (word-lines))
  (faces-test:without-outer-diagnostic!)
  (test-browser:wait-for-applied page)
  (check-equal? '("none" "inline" ()) (word-lines))
  (faces-test:show-fixture!))

(faces-test:show-samples!)

(faces-test:set-case! page #f ":root { --tuna-font-size-code: 17px; --tuna-surface-subtle: rgb(1, 2, 3); }")

(test "Markdown's inline code and code blocks draw in the code font and size, on the subtle surface, in markup.raw's colour"
  (let ([shot (faces-test:snapshot page)])
    (for-each
      (lambda (class)
        (let ([e (car (faces-test:with-class shot class))])
          (check-equal? (list class "Fira Code" "17px" "rgb(1, 2, 3)" (base-style faces:markup.raw "color"))
                        (list class (faces-test:family shot e) (faces-test:style shot e "font-size")
                              (faces-test:style shot e "background-color") (faces-test:style shot e "color")))))
      '("markdown-code" "markdown-code-block"))))

(test "a strong element in a face that sets no weight stays bold"
  (let ([shot (faces-test:snapshot page)])
    (check-equal? '("strong" "700")
                  (let ([e (find (lambda (i) (equal? "STRONG" (faces-test:name shot i))) (faces-test:with-face shot faces:keyword))])
                    (list (string-downcase (faces-test:name shot e)) (faces-test:style shot e "font-weight"))))))

(test "a transient key drawn in key-binding takes key-binding's font and colour"
  (let* ([shot (faces-test:snapshot page)] [k (car (faces-test:with-class shot "transient-key"))])
    (check-equal? (list "Fira Code" (base-style faces:key-binding "color")) (list (faces-test:family shot k) (faces-test:style shot k "color")))))
