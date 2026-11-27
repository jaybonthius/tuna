(import (tuna) (test) (test-browser) (cdp page) (design-tokens) (faces) (buffers) (views) (layout) (layout-split) (editing)
        (echo-area) (status-line) (minibuffer) (completion) (completion-list) (completion-annotations) (files) (file-picker)
        (command-picker) (dired) (options) (faces-test))

(define page (test-browser:open (page-options [width 1400] [height 1000] [color-scheme (color-scheme light)])))

(define (style-of shot text face property) (faces-test:style shot (faces-test:faced shot text face) property))

(define (item-style looks face property) (cdr (assoc property (cdr (assq face looks)))))

(define (case-looks theme? css)
  (faces-test:set-case! page theme? css)
  (faces-test:item-looks (faces-test:snapshot page)))

(define (weights looks faces) (map (lambda (f) (item-style looks f "font-weight")) faces))

(define (pixels size) (string->number (substring size 0 (- (string-length size) 2))))

(define (in-entry-marked? shot i)
  (exists (lambda (a) (and (faces-test:has-class? shot a "dired-entry") (equal? "*" (faces-test:attribute shot a "data-mark"))))
          (faces-test:ancestors shot i)))

(define (dired-weights)
  (let* ([shot (faces-test:dired-shot page)]
         [weight (lambda (i) (faces-test:style shot i "font-weight"))]
         [header (car (faces-test:with-face shot 'dired.header))])
    (list (weight (find (lambda (i) (faces-test:has-class? shot i "line")) (faces-test:descendants shot header)))
          (weight (find (lambda (i) (in-entry-marked? shot i)) (faces-test:with-face shot 'dired.mark)))
          (weight (car (faces-test:with-face shot 'dired.marked)))
          (weight (car (faces-test:with-face shot 'dired.flagged))))))

(define (completion-match-weight)
  (let ([shot (faces-test:completion-rows page)])
    (faces-test:style shot
      (find (lambda (i)
              (let ([face (faces-test:attribute shot i "data-face")])
                (and face (> (string-length face) 16) (string=? "completion.match" (substring face 0 16)))))
            (faces-test:with-class shot "completion-match"))
      "font-weight")))

(define constructs
  (list faces:keyword faces:function.builtin faces:type faces:module faces:string.escape faces:error faces:warning faces:success
        faces:escape-glyph))

(define headings
  (list faces:markup.heading.1 faces:markup.heading.2 faces:markup.heading.3 faces:markup.heading.4 faces:markup.heading.5
        faces:markup.heading.6))

;; Matches are drawn in completion's faces under the any-order style.
(options:set! completion:styles (list completion:any-order))

(faces-test:show-fixture!)

(define plain (case-looks #f ""))

(define modus (case-looks #t ""))

(define text-size (pixels (item-style plain faces:keyword "font-size")))

(define (size-ratio looks face)
  (/ (exact (round (* 100 (/ (pixels (item-style looks face "font-size")) text-size)))) 100))

(test "Modus's constructs are plain by default: no bold, no slanted comments, dired's header and mark and completion's match at 400"
  (check-equal? (map (lambda (f) "400") constructs) (weights modus constructs))
  (check-equal? '("normal" "normal" "normal")
                (map (lambda (f) (item-style modus f "font-style")) (list faces:comment faces:comment.documentation faces:string.documentation)))
  (check-equal? '("400" "400") (list-head (dired-weights) 2))
  (check-equal? "400" (completion-match-weight)))

(test "under Modus a keyword in a heading is bold, a directive in one is not"
  (let ([shot (faces-test:snapshot page)])
    (check-equal? '("700" "400")
                  (list (style-of shot "hkw" faces:keyword "font-weight") (style-of shot "hdir" faces:keyword.directive "font-weight")))))

(test "Modus always bolds headings, strong text, key bindings, dired's marked and flagged entries and the prompt"
  (check-equal? (map (lambda (f) "700") (append headings (list faces:markup.strong faces:key-binding)))
                (weights modus (append headings (list faces:markup.strong faces:key-binding))))
  (check-equal? '("700" "700") (list-tail (dired-weights) 2))
  (test-browser:press! page "M-x")
  (faces-test:wait-for page ".minibuffer-question")
  (let ([shot (faces-test:snapshot page)])
    (faces-test:quit-prompt! page)
    (check-equal? "700" (faces-test:style shot (car (faces-test:with-class shot "minibuffer-question")) "font-weight")))
  (check-equal? "rgb(166, 0, 0)" (item-style modus faces:key-binding "color")))

(test "--modus-bold-constructs bolds the constructs alone, with dired's header and mark and completion's match"
  (let ([looks (case-looks #t ":root { --modus-bold-constructs: bold; }")])
    (check-equal? (map (lambda (f) "700") constructs) (weights looks constructs))
    (check-equal? '("400" "400" "400" "400" "400")
                  (weights looks (list faces:keyword.directive faces:function faces:function.call faces:string faces:constant)))
    (check-equal? '("700" "700") (list-head (dired-weights) 2))
    (check-equal? "700" (completion-match-weight))))

(test "Modus's bold follows --tuna-font-weight-bold, and the constructs follow it when set to it"
  (let ([looks (case-looks #t ":root { --tuna-font-weight-bold: 600; }")])
    (check-equal? '("600" "600" "600") (weights looks (list faces:markup.heading.1 faces:markup.strong faces:key-binding)))
    (check-equal? '("600" "600") (list-tail (dired-weights) 2)))
  (let ([looks (case-looks #t ":root { --tuna-font-weight-bold: 600; --modus-bold-constructs: var(--tuna-font-weight-bold); }")])
    (check-equal? (map (lambda (f) "600") constructs) (weights looks constructs))))

(test "--modus-italic-constructs slants comments, documentation and quotes alone"
  (let* ([looks (case-looks #t ":root { --modus-italic-constructs: italic; }")]
         [slanted (list faces:comment faces:comment.documentation faces:string.documentation faces:markup.quote)])
    (check-equal? '("italic" "italic" "italic" "italic") (map (lambda (f) (item-style looks f "font-style")) slanted))
    (check-equal? '()
                  (filter (lambda (f) (and (not (memq f slanted)) (not (equal? (item-style looks f "font-style") (item-style modus f "font-style")))))
                          (map car looks)))))

(test "Modus colours the six heading levels with its heading colours"
  (check-equal? '("rgb(0, 0, 0)" "rgb(87, 67, 22)" "rgb(25, 54, 104)" "rgb(114, 16, 69)" "rgb(42, 80, 69)" "rgb(127, 0, 0)")
                (map (lambda (f) (item-style modus f "color")) headings)))

(test "a heading level's size token sets that level alone"
  (let* ([looks (case-looks #t (string-append ":root { --faces-markup-heading-1-font-size: 1.3em; --faces-markup-heading-2-font-size: 1.2em;"
                                              " --faces-markup-heading-3-font-size: 1.1em; }"))]
         [ratios (map (lambda (f) (size-ratio looks f)) (list-head headings 4))])
    (check-equal? '(13/10 6/5 11/10 1) ratios)))

(test "the heading family's size reaches every level, and a level's own size beats it"
  (let* ([ratio size-ratio]
         [family (case-looks #t ":root { --faces-markup-heading-font-size: 1.1em; }")])
    (check-equal? '(11/10 11/10 11/10 11/10)
                  (map (lambda (f) (ratio family f)) (list faces:markup.heading.1 faces:markup.heading.2 faces:markup.heading.6 faces:markup.heading)))
    (let ([level (case-looks #t ":root { --faces-markup-heading-font-size: 1.1em; --faces-markup-heading-1-font-size: 1.5em; }")])
      (check-equal? '(3/2 11/10 11/10 11/10 11/10 11/10) (map (lambda (f) (ratio level f)) headings)))))

(test "Modus underlines links and diagnostics in its colours and leaves the text of unnecessary code and matches black"
  (check-equal?
    '(("underline" "solid" "rgb(53, 70, 194)") ("underline" "solid" "rgb(89, 89, 89)") ("underline" "wavy" "rgb(208, 0, 0)")
      ("underline" "wavy" "rgb(128, 128, 0)") ("underline" "wavy" "rgb(0, 136, 153)") ("underline" "wavy" "rgb(0, 136, 153)")
      ("underline" "wavy" "rgb(0, 136, 153)"))
    (map (lambda (f) (map (lambda (p) (item-style modus f p)) '("text-decoration-line" "text-decoration-style" "text-decoration-color")))
         (list faces:markup.link faces:markup.underline faces:diagnostic.error faces:diagnostic.warning faces:diagnostic.info
               faces:diagnostic.hint faces:diagnostic.unnecessary)))
  (check-equal? '("rgb(0, 0, 0)" "rgb(0, 0, 0)" "rgb(0, 0, 0)")
                (map (lambda (f) (item-style modus f "color")) (list faces:diagnostic.unnecessary faces:match faces:match.other))))

(test "a Modus palette token set by the user recolours what reads it"
  (check-equal? "rgb(0, 0, 0)" (item-style (case-looks #t ":root { --modus-keyword: var(--modus-fg-main); }") faces:keyword "color")))

(test "under Modus a dired folder is not bold"
  (faces-test:set-case! page #t "")
  (let ([shot (faces-test:dired-shot page)])
    (check-equal? "400" (faces-test:style shot (car (faces-test:with-face shot 'dired.folder)) "font-weight"))))

(test "a face's colour token holding inherit falls to faces' default, and currentcolor takes the surrounding text's"
  (let ([themed (item-style modus faces:keyword "color")]
        [inherited (item-style (case-looks #t ":root { --faces-keyword-color: inherit; }") faces:keyword "color")])
    (check-equal? (item-style plain faces:keyword "color") inherited)
    (check (not (equal? themed inherited)))
    (faces-test:set-case! page #t ":root { --faces-keyword-color: currentcolor; }")
    (let* ([shot (faces-test:snapshot page)] [e (faces-test:faced shot "if" faces:keyword)]
           [own (faces-test:style shot e "color")])
      (check-equal? (faces-test:style shot (faces-test:parent shot e) "color") own)
      (check (not (equal? themed own))))))
