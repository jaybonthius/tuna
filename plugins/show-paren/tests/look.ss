(import (tuna) (test) (test-user) (show-paren) (design-tokens-test css) (sexp-test scene))

(define rules (design-tokens-test/css:file-rules "show-paren/show-paren.css"))

(define (rule-for face)
  (find (lambda (r) (equal? (string-append "[data-face=\"show-paren." face "\"]") (design-tokens-test/css:rule-selector r)))
        rules))

(define (chain face property)
  (design-tokens-test/css:var-chain (design-tokens-test/css:declaration (rule-for face) property)))

(test "a match takes the match background through its own token, in the defaults layer"
  (check-equal? '("--show-paren-match-background" "--tuna-match") (chain "match" "background-color"))
  (check-equal? "defaults.faces" (design-tokens-test/css:rule-layer (rule-for "match"))))

(test "a mismatch is in the error colour on its surface, and bold, so it shows by more than colour"
  (check-equal? '(("--show-paren-mismatch-color" "--tuna-error") ("--show-paren-mismatch-background" "--tuna-error-surface")
                  ("--show-paren-mismatch-font-weight" "--tuna-font-weight-bold"))
                (map (lambda (p) (chain "mismatch" p)) '("color" "background-color" "font-weight"))))

(test "under forced colours both faces are outlined"
  (let ([forced (filter (lambda (r) (equal? "preferences @media (forced-colors: active)" (design-tokens-test/css:rule-layer r))) rules)])
    (check-equal? '("1px solid CanvasText") (map (lambda (r) (design-tokens-test/css:declaration r "outline")) forced))))

(test "a highlighted bracket is drawn with its face"
  (sexp-test/scene:show! "(a b)|")
  (test-user:settle)
  (check-equal? '("show-paren.match" "show-paren.match")
                (filter (lambda (v) (and (string? v) (string=? v "show-paren.match")))
                        (map (lambda (e) (test-user:element-attribute e "data-face"))
                             (test-user:elements-with (test-user:screen) "data-face")))))
