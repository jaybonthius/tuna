(import (tuna) (test) (design-tokens-test css))

(define rules (design-tokens-test/css:file-rules "rainbow-delimiters/rainbow-delimiters.css"))

(define (rule-for face)
  (find (lambda (r) (equal? (string-append "[data-face=\"rainbow-delimiters." face "\"]") (design-tokens-test/css:rule-selector r)))
        rules))

(define (chain face property)
  (design-tokens-test/css:var-chain (design-tokens-test/css:declaration (rule-for face) property)))

(test "each depth's colour is its component token, falling back to a design token"
  (check-equal? '(("--rainbow-delimiters-depth-1-color" "--tuna-text") ("--rainbow-delimiters-depth-2-color" "--tuna-pink-11")
                  ("--rainbow-delimiters-depth-3-color" "--tuna-cyan-11") ("--rainbow-delimiters-depth-4-color" "--tuna-orange-11")
                  ("--rainbow-delimiters-depth-5-color" "--tuna-yellow-11") ("--rainbow-delimiters-depth-6-color" "--tuna-violet-11")
                  ("--rainbow-delimiters-depth-7-color" "--tuna-green-11") ("--rainbow-delimiters-depth-8-color" "--tuna-indigo-11")
                  ("--rainbow-delimiters-depth-9-color" "--tuna-purple-11"))
                (map (lambda (n) (chain (string-append "depth-" (number->string n)) "color")) (cdr (iota 10))))
  (check (for-all (lambda (n) (equal? "defaults.faces" (design-tokens-test/css:rule-layer (rule-for (string-append "depth-" (number->string n))))))
                  (cdr (iota 10)))))

(test "unmatched and mismatched brackets are in the error and warning colours on their surfaces, and bold"
  (check-equal? '(("--rainbow-delimiters-unmatched-color" "--tuna-error") ("--rainbow-delimiters-unmatched-background" "--tuna-error-surface")
                  ("--rainbow-delimiters-unmatched-font-weight" "--tuna-font-weight-bold"))
                (map (lambda (p) (chain "unmatched" p)) '("color" "background-color" "font-weight")))
  (check-equal? '(("--rainbow-delimiters-mismatched-color" "--tuna-warning") ("--rainbow-delimiters-mismatched-background" "--tuna-warning-surface")
                  ("--rainbow-delimiters-mismatched-font-weight" "--tuna-font-weight-bold"))
                (map (lambda (p) (chain "mismatched" p)) '("color" "background-color" "font-weight"))))

(test "under forced colours unmatched and mismatched brackets are underlined"
  (let ([forced (filter (lambda (r) (equal? "preferences @media (forced-colors: active)" (design-tokens-test/css:rule-layer r))) rules)])
    (check-equal? '("underline") (map (lambda (r) (design-tokens-test/css:declaration r "text-decoration-line")) forced))))
