(import (tuna) (test) (design-tokens-test css))

(define rules (design-tokens-test/css:file-rules "markdown/markdown.css"))

(define (selects? r selector)
  (member selector (map design-tokens-test/css:trim (design-tokens-test/css:split (design-tokens-test/css:rule-selector r) #\,))))

(define (declaration selector property)
  (exists (lambda (r) (and (selects? r selector) (design-tokens-test/css:declaration r property))) rules))

(test "every rule is in the layer defaults"
  (check-equal? '("defaults") (fold-left (lambda (acc r) (if (member (design-tokens-test/css:rule-layer r) acc) acc (cons (design-tokens-test/css:rule-layer r) acc)))
                                         '() rules)))

(test "a drawing keeps its newlines; headings are semibold, levels 1 to 3 larger"
  (check-equal? "pre-wrap" (declaration ".markdown" "white-space"))
  (check-equal? "var(--tuna-font-weight-semibold)" (declaration ".markdown-heading" "font-weight"))
  (check-equal? '("var(--tuna-font-size-6)" "var(--tuna-font-size-5)" "var(--tuna-font-size-4)")
                (map (lambda (n) (declaration (format ".markdown-heading[aria-level=\"~a\"]" n) "font-size")) '(1 2 3))))

(test "code, inline and in blocks, is in the code font and size, on the code block background, falling back to the subtle surface"
  (check-equal? '("var(--tuna-font-code)" "var(--tuna-font-size-code)" "var(--tuna-font-code)")
                (list (declaration ".markdown-code" "font-family") (declaration ".markdown-code" "font-size")
                      (declaration ".markdown-code-block" "font-family")))
  (check-equal? '("--markdown-code-block-background" "--tuna-surface-subtle")
                (design-tokens-test/css:var-chain (declaration ".markdown-code" "background")))
  (check-equal? '("--markdown-code-block-radius" "--tuna-panel-radius")
                (design-tokens-test/css:var-chain (declaration ".markdown-code-block" "border-radius")))
  (check-equal? "var(--tuna-text-muted)" (declaration ".markdown-code-block[data-language]::before" "color")))

(test "a quote's rule and a table's lines fall back to the border token; the header row is on the subtle surface"
  (check (member "--markdown-quote-border" (map car (design-tokens-test/css:references (declaration ".markdown-quote" "border-inline-start")))))
  (check (member "--markdown-table-border" (map car (design-tokens-test/css:references (declaration ".markdown-table-cell" "border")))))
  (check-equal? "var(--tuna-surface-subtle)" (declaration ".markdown-table-cell[role=\"columnheader\"]" "background")))

(test "a drawn link is in the link colour and underlined"
  (check-equal? '("var(--tuna-link)" "underline") (list (declaration ".markdown-link" "color") (declaration ".markdown-link" "text-decoration"))))
