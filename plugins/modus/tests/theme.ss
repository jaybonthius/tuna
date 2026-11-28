(import (tuna) (test) (web) (tables) (design-tokens-test css) (design-tokens-test colours) (design-tokens-test token-file) (modus-test modus-file) (modus))

(define (named suffix) (filter (lambda (d) (not (design-tokens-test/css:prefix? "--tuna-" (car d)))) (modus-test/modus-file:attributes suffix)))

(test "the modus theme registers its file as the theme"
  (check-equal? "modus/modus.css" (tables:ref web:stylesheets 'theme #f)))

(test "its palette is Modus's: 109 named colours and 53 of Modus's mappings, each a pair of the operandi-tinted and the vivendi-tinted value"
  (check-equal? 162 (length modus-test/modus-file:colours))
  (check-equal? '() (filter (lambda (d) (not (and (design-tokens-test/css:prefix? "light-dark(#" (cdr d)) (= 2 (length (design-tokens-test/colours:hex-colours (cdr d)))))))
                            modus-test/modus-file:colours))
  (check-equal? '("light-dark(#fbf7f0, #0d0e1c)" "light-dark(#d00000, #ff66ff)")
    (map (lambda (n) (cdr (assoc n modus-test/modus-file:colours))) '("--modus-bg-main" "--modus-cursor"))))

(define colour-semantic-names
  (filter (lambda (n) (not (or (design-tokens-test/css:prefix? "font-" n) (design-tokens-test/css:prefix? "line-height" n)
                               (member n '("control-radius" "panel-radius" "border-width" "focus-width" "shadow-raised" "bar-size"
                                           "control-size" "duration" "ease")))))
          design-tokens-test/token-file:semantic-names))

;; Modus's two options are variables the user declares, so the theme
;; reads them undeclared; its bold faces read the bold weight's token.
(test "it sets every colour among the semantic tokens, names no token the token file lacks, and reads only its palette, its two options and the bold weight"
  (check-equal? 135 (length modus-test/modus-file:mapping))
  (check-equal? '() (filter (lambda (n) (not (assoc (string-append "--tuna-" n) modus-test/modus-file:mapping))) colour-semantic-names))
  (check-equal? '() (filter (lambda (d) (and (design-tokens-test/css:prefix? "--tuna-" (car d)) (not (design-tokens-test/token-file:declared? (car d))))) modus-test/modus-file:mapping))
  (check-equal? '()
    (filter (lambda (r) (not (or (assoc r modus-test/modus-file:colours)
                                 (member r '("--modus-bold-constructs" "--modus-italic-constructs" "--tuna-font-weight-bold")))))
            (map car (apply append (map (lambda (d) (design-tokens-test/css:references (cdr d))) modus-test/modus-file:mapping))))))

(test "faces' and components' colours take Modus's, as Emacs's faces do under Modus"
  (check-equal? '(("--faces-comment-color" . "var(--modus-comment)") ("--faces-comment-documentation-color" . "var(--modus-docstring)") ("--faces-string-color" . "var(--modus-string)") ("--faces-string-escape-color" . "var(--modus-rx-backslash)") ("--faces-number-color" . "var(--modus-number)") ("--faces-keyword-color" . "var(--modus-keyword)") ("--faces-keyword-directive-color" . "var(--modus-preprocessor)") ("--faces-function-color" . "var(--modus-fnname)") ("--faces-builtin-color" . "var(--modus-builtin)") ("--faces-type-color" . "var(--modus-type)") ("--faces-module-color" . "var(--modus-type)") ("--faces-constant-color" . "var(--modus-constant)") ("--faces-variable-definition-color" . "var(--modus-variable)") ("--faces-variable-color" . "var(--modus-variable-use)") ("--faces-variable-member-color" . "var(--modus-property)") ("--faces-function-call-color" . "var(--modus-fnname-call)") ("--faces-string-regexp-color" . "var(--modus-string)") ("--faces-attribute-color" . "var(--modus-type)") ("--faces-property-color" . "var(--modus-property)") ("--faces-tag-color" . "var(--modus-fnname)") ("--faces-markup-heading-color" . "var(--modus-fg-heading-1)") ("--faces-markup-raw-color" . "var(--modus-fg-prose-code)") ("--faces-markup-heading-1-color" . "var(--modus-fg-heading-1)") ("--faces-markup-heading-2-color" . "var(--modus-fg-heading-2)") ("--faces-markup-heading-3-color" . "var(--modus-fg-heading-3)") ("--faces-markup-heading-4-color" . "var(--modus-fg-heading-4)") ("--faces-markup-heading-5-color" . "var(--modus-fg-heading-5)") ("--faces-markup-heading-6-color" . "var(--modus-fg-heading-6)") ("--faces-markup-quote-color" . "var(--modus-docstring)") ("--faces-markup-link-color" . "var(--modus-fg-link)") ("--faces-diagnostic-unnecessary-color" . "currentcolor") ("--faces-match-color" . "var(--modus-fg-search-current)") ("--faces-match-other-color" . "var(--modus-fg-search-lazy)") ("--faces-escape-glyph-color" . "var(--modus-keybind)") ("--faces-key-binding-color" . "var(--modus-keybind)") ("--dired-marked-color" . "var(--modus-fg-mark-select)") ("--dired-flagged-color" . "var(--modus-fg-mark-delete)") ("--minibuffer-prompt-color" . "var(--modus-fg-prompt)") ("--echo-area-prompt-color" . "var(--modus-fg-prompt)") ("--completion-match-0-color" . "var(--modus-fg-completion-match-0)") ("--completion-match-1-color" . "var(--modus-fg-completion-match-1)") ("--completion-match-2-color" . "var(--modus-fg-completion-match-2)") ("--completion-match-3-color" . "var(--modus-fg-completion-match-3)") ("--layout-part-mode-color" . "var(--modus-magenta-cooler)") ("--views-region-color" . "var(--modus-fg-region)") ("--rainbow-delimiters-depth-1-color" . "var(--modus-fg-main)") ("--rainbow-delimiters-depth-2-color" . "var(--modus-magenta-intense)") ("--rainbow-delimiters-depth-3-color" . "var(--modus-cyan-intense)") ("--rainbow-delimiters-depth-4-color" . "var(--modus-red-warmer)") ("--rainbow-delimiters-depth-5-color" . "var(--modus-yellow-intense)") ("--rainbow-delimiters-depth-6-color" . "var(--modus-magenta-cooler)") ("--rainbow-delimiters-depth-7-color" . "var(--modus-green-intense)") ("--rainbow-delimiters-depth-8-color" . "var(--modus-blue-warmer)") ("--rainbow-delimiters-depth-9-color" . "var(--modus-magenta-warmer)") ("--which-key-key-color" . "var(--modus-keybind)") ("--which-key-label-color" . "var(--modus-type)")) (named "-color")))

(test "backgrounds and decorations take Modus's"
  (check-equal? '(("--dired-marked-background" . "var(--modus-bg-mark-select)") ("--dired-flagged-background" . "var(--modus-bg-mark-delete)") ("--search-group-1-background" . "var(--modus-bg-blue-intense)") ("--isearch-fail-background" . "var(--modus-bg-red-intense)") ("--replace-match-background" . "var(--modus-bg-red-intense)") ("--occur-match-background" . "var(--modus-bg-magenta-subtle)") ("--search-group-2-background" . "var(--modus-bg-green-intense)") ("--show-paren-match-background" . "var(--modus-bg-paren-match)") ("--faces-markup-link-text-decoration" . "underline var(--modus-underline-link)") ("--faces-markup-underline-text-decoration" . "underline var(--modus-fg-dim)") ("--faces-diagnostic-error-text-decoration" . "underline wavy var(--modus-underline-err)") ("--faces-diagnostic-warning-text-decoration" . "underline wavy var(--modus-underline-warning)") ("--faces-diagnostic-info-text-decoration" . "underline wavy var(--modus-underline-note)") ("--faces-diagnostic-hint-text-decoration" . "underline wavy var(--modus-underline-note)") ("--faces-diagnostic-unnecessary-text-decoration" . "underline wavy var(--modus-underline-note)")) (append (modus-test/modus-file:attributes "-background") (modus-test/modus-file:attributes "-text-decoration"))))

(test "heading levels take Modus's six heading colours"
  (check-equal? '("#000000" "#574316" "#193668" "#721045" "#2a5045" "#7f0000")
    (map (lambda (n) (modus-test/modus-file:colour-of (format "--faces-markup-heading-~a-color" n) 'light)) '(1 2 3 4 5 6)))
  (check-equal? '("#ffffff" "#d2b580" "#82b0ec" "#feacd0" "#88ca9f" "#ef8386")
    (map (lambda (n) (modus-test/modus-file:colour-of (format "--faces-markup-heading-~a-color" n) 'dark)) '(1 2 3 4 5 6))))

(test "Modus's two options are undeclared; faces whose bold Modus clears read normal when off, its always-bold faces the bold weight"
  (check-equal? '(#f #f) (map modus-test/modus-file:declares? '("--modus-bold-constructs" "--modus-italic-constructs")))
  (check-equal? '(("--faces-key-binding-font-weight" . "var(--tuna-font-weight-bold)") ("--dired-marked-font-weight" . "var(--tuna-font-weight-bold)") ("--dired-flagged-font-weight" . "var(--tuna-font-weight-bold)") ("--dired-folder-font-weight" . "normal") ("--faces-keyword-directive-font-weight" . "normal") ("--faces-keyword-font-weight" . "var(--modus-bold-constructs)") ("--faces-builtin-font-weight" . "var(--modus-bold-constructs)") ("--faces-type-font-weight" . "var(--modus-bold-constructs)") ("--faces-module-font-weight" . "var(--modus-bold-constructs)") ("--faces-attribute-font-weight" . "var(--modus-bold-constructs)") ("--faces-string-escape-font-weight" . "var(--modus-bold-constructs)") ("--faces-escape-glyph-font-weight" . "var(--modus-bold-constructs)") ("--faces-error-font-weight" . "var(--modus-bold-constructs, normal)") ("--faces-warning-font-weight" . "var(--modus-bold-constructs, normal)") ("--faces-success-font-weight" . "var(--modus-bold-constructs, normal)") ("--completion-match-0-font-weight" . "var(--modus-bold-constructs, normal)") ("--completion-match-1-font-weight" . "var(--modus-bold-constructs, normal)") ("--completion-match-2-font-weight" . "var(--modus-bold-constructs, normal)") ("--completion-match-3-font-weight" . "var(--modus-bold-constructs, normal)") ("--dired-header-font-weight" . "var(--modus-bold-constructs, normal)") ("--dired-mark-font-weight" . "var(--modus-bold-constructs, normal)")) (modus-test/modus-file:attributes "-font-weight"))
  (check-equal? '(("--faces-comment-font-style" . "var(--modus-italic-constructs)") ("--faces-markup-quote-font-style" . "var(--modus-italic-constructs)")) (modus-test/modus-file:attributes "-font-style")))

(test "text is at least Modus's 7:1 on the page, the popups, the chrome, the active bar and the selection, and on the region in light"
  (check-equal? '((19.66 19.15) (18.08 17.78) (14.48 13.0) (11.09 8.29) (13.23 9.09) (11.15 6.91))
    (map (lambda (bg) (modus-test/modus-file:theme-contrast "text" bg)) '("surface" "surface-raised" "chrome" "bar" "selected" "region")))
  (check-equal? '((7.01 8.08) (7.5 6.41) (6.56 6.64) (6.56 6.64))
    (map (lambda (fg) (modus-test/modus-file:theme-contrast fg "surface")) '("link" "error" "text-muted" "text-faint")))
  (check-equal? '((4.83 4.51) (5.07 4.54))
    (list (modus-test/modus-file:theme-contrast "text-muted" "chrome") (modus-test/modus-file:theme-contrast "on-bar-inactive" "bar-inactive"))))

(test "a link is under 4.5:1 on the selection in dark, so a match on the selected row takes the row's text colour"
  (check-equal? '(4.72 3.83) (modus-test/modus-file:theme-contrast "link" "selected")))

(test "the completion match colours meet 7:1 on the page but some fall under 4.5:1 on the selection in dark"
  (check-equal? '(((9.77 8.79) (6.58 4.17)) ((8.11 9.15) (5.46 4.35)) ((7.02 12.23) (4.72 5.81)) ((7.5 9.92) (5.05 4.71)))
    (map (lambda (k) (let ([fg (format "fg-completion-match-~a" k)])
                       (list (modus-test/modus-file:palette-contrast fg "bg-main") (modus-test/modus-file:palette-contrast fg "bg-completion"))))
         '(0 1 2 3))))

(test "focus meets 3:1 on the active bar and the page; the split's rule and the chrome stand off the islands"
  (check-equal? '((3.95 3.5) (7.01 8.08) (2.72 3.29) (1.36 1.47))
    (list (modus-test/modus-file:theme-contrast "focus" "bar") (modus-test/modus-file:theme-contrast "focus" "surface")
          (modus-test/modus-file:theme-contrast "border" "surface") (modus-test/modus-file:theme-contrast "chrome" "surface"))))

(test "a strip's edge cards, bordered in the strong border on the chrome, meet WCAG's 3:1 for graphics"
  (check-equal? '(5.22 4.45) (modus-test/modus-file:theme-contrast "border-strong" "chrome")))

(test "turning the theme off takes its file back"
  (unload-owner! (module-owner '(modus)))
  (check-equal? #f (tables:ref web:stylesheets 'theme #f)))
