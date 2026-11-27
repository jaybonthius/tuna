(import (tuna) (test) (test-browser) (cdp page) (design-tokens) (faces) (views) (layout) (layout-split) (editing)
        (echo-area) (status-line) (minibuffer) (faces-test))

(define page (test-browser:open (page-options [width 1400] [height 1000] [color-scheme (color-scheme light)])))

(define transparent "rgba(0, 0, 0, 0)")

(define (style-of shot text face property) (faces-test:style shot (faces-test:faced shot text face) property))

(define (region-around shot i)
  (or (find (lambda (a) (faces-test:has-class? shot a "region")) (faces-test:ancestors shot i))
      (errorf 'region-around "not in the region")))

(define (region-background shot text face)
  (faces-test:style shot (region-around shot (faces-test:faced shot text face)) "background-color"))

(faces-test:show-fixture!)

(faces-test:set-case! page #f "")

(define keyword-color (style-of (faces-test:snapshot page) "if" faces:keyword "color"))

(faces-test:region! "ab" 0 "rka")

(test-browser:wait-for-applied page)

(test "the region draws its background over a face's and keeps the face's colour, weight and slant"
  (let* ([shot (faces-test:snapshot page)] [region (region-background shot "rkw" faces:keyword)])
    (check-equal? (list keyword-color region)
                  (list (style-of shot "rkw" faces:keyword "color") (style-of shot "r+" faces:diff.plus "background-color")))
    (faces-test:set-case! page #f
      ":root { --faces-keyword-font-weight: bold; --faces-keyword-font-style: italic; --faces-keyword-background: rgb(4, 5, 6); }")
    (let ([shot (faces-test:snapshot page)])
      (check-equal? (list "700" "italic" region)
                    (map (lambda (p) (style-of shot "rkw" faces:keyword p)) '("font-weight" "font-style" "background-color"))))
    (faces-test:set-case! page #f "")))

(test "a match drawn above the region keeps its background on it; a keyword above shows the region's"
  (let* ([shot (faces-test:snapshot page)] [region (region-background shot "rkw" faces:keyword)]
         [match (style-of shot "rm" faces:match "background-color")])
    (check (not (member match (list transparent region))))
    (check-equal? (list transparent region)
                  (list (style-of shot "rka" faces:keyword "background-color") (region-background shot "rka" faces:keyword)))
    (faces-test:region! "mmrr" 2 "mmrr")
    (test-browser:wait-for-applied page)
    ;; views draws the region outermost, so where the region crosses a
    ;; match above it, the match is drawn inside the region's piece.
    (let* ([shot (faces-test:snapshot page)] [inside (faces-test:faced shot "rr" faces:match)])
      (check-equal? (list match region)
                    (list (faces-test:style shot inside "background-color")
                          (faces-test:style shot (region-around shot inside) "background-color"))))
    (faces-test:no-region!)))

(test "under Modus the region keeps a keyword's colour"
  (faces-test:set-case! page #t "")
  (faces-test:region! "ab" 0 "rka")
  (test-browser:wait-for-applied page)
  (check-equal? "rgb(0, 0, 0)" (style-of (faces-test:snapshot page) "rkw" faces:keyword "color")))
