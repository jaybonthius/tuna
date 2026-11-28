(import (tuna) (test) (design-tokens-test css))

;; No name of the plugin lists its faces, so they are read from its
;; source, as data.
(define defined-faces
  (call-with-input-file (string-append (path-parent (car (command-line))) "/plugins/faces/src/faces.sls")
    (lambda (p)
      (get-line p)
      (let loop ([acc '()])
        (let ([form (read p)])
          (cond
            [(eof-object? form) (reverse acc)]
            [(and (pair? form) (eq? 'define (car form)) (symbol? (cadr form)))
             (loop (cons (symbol->string (cadr form)) acc))]
            [else (loop acc)]))))))

(define (face-rule? r) (design-tokens-test/css:prefix? "[data-face" (design-tokens-test/css:rule-selector r)))

(define (face-of-rule r)
  (let* ([sel (design-tokens-test/css:rule-selector r)] [from (+ (design-tokens-test/css:search sel "\"" 0) 1)])
    (substring sel from (design-tokens-test/css:search sel "\"" from))))

(define faces-rules (design-tokens-test/css:file-rules "faces/faces.css"))

(define face-stylesheets
  (filter (lambda (file) (exists (lambda (r) (string=? "defaults.faces" (design-tokens-test/css:rule-layer r))) (design-tokens-test/css:file-rules file)))
          (design-tokens-test/css:stylesheets)))

(define styled-faces
  (map face-of-rule (filter (lambda (r) (and (string=? "defaults.faces" (design-tokens-test/css:rule-layer r)) (design-tokens-test/css:prefix? "[data-face=\"" (design-tokens-test/css:rule-selector r))))
                            faces-rules)))

(define (rule-chain file face property)
  (design-tokens-test/css:var-chain (design-tokens-test/css:declaration (find (lambda (r) (and (string=? "defaults.faces" (design-tokens-test/css:rule-layer r)) (face-rule? r) (string=? face (face-of-rule r))))
                                        (design-tokens-test/css:file-rules file))
                                  property)))

(test "every face the plugin defines has a rule of its own in its stylesheet, which styles no other name"
  (check-equal? 78 (length defined-faces))
  (check-equal? '() (filter (lambda (f) (not (member f styled-faces))) defined-faces))
  (check-equal? '() (filter (lambda (f) (not (member f defined-faces))) styled-faces)))

(test "every face rule, in faces.css and in every plugin's stylesheet, is in the sub-layer defaults.faces"
  (check-equal? '()
    (apply append
      (map (lambda (file)
             (map (lambda (r) (list file (design-tokens-test/css:rule-layer r) (design-tokens-test/css:rule-selector r)))
                  (filter (lambda (r) (and (face-rule? r) (not (string=? "defaults.faces" (design-tokens-test/css:rule-layer r)))
                                           (not (design-tokens-test/css:prefix? "preferences" (design-tokens-test/css:rule-layer r)))))
                          (design-tokens-test/css:file-rules file))))
           (design-tokens-test/css:stylesheets)))))

(define seven
  '(("color" . "color") ("background-color" . "background") ("font-weight" . "font-weight") ("font-style" . "font-style")
    ("font-family" . "font-family") ("font-size" . "font-size") ("text-decoration" . "text-decoration")))

(define (hyphens s) (list->string (map (lambda (c) (if (char=? c #\.) #\- c)) (string->list s))))

(define (own-token file face suffix)
  (if (string=? file "faces/faces.css")
      (string-append "--faces-" (if (string=? face "") "builtin" (hyphens face)) "-" suffix)
      (string-append "--" (hyphens face) "-" suffix)))

(test "each face rule declares the seven properties, each reading the face's own token first and ending in a default or revert-layer"
  (check-equal? 142
    (length (filter (lambda (r) (string=? "defaults.faces" (design-tokens-test/css:rule-layer r)))
                    (apply append (map design-tokens-test/css:file-rules face-stylesheets)))))
  (check-equal? '()
    (apply append
      (map (lambda (file)
             (fold-right
               (lambda (r acc)
                 (if (not (string=? "defaults.faces" (design-tokens-test/css:rule-layer r)))
                     acc
                     (let* ([face (if (design-tokens-test/css:prefix? "[data-face$=" (design-tokens-test/css:rule-selector r)) "" (face-of-rule r))]
                            [ds (design-tokens-test/css:rule-declarations r)]
                            [bad (filter (lambda (p)
                                           (let ([d (assoc (car p) ds)])
                                             (not (and d
                                                       (let ([c (design-tokens-test/css:var-chain (cdr d))])
                                                         (and (string=? (car c) (own-token file face (cdr p)))
                                                              (for-all (lambda (t) (design-tokens-test/css:suffix? (cdr p) t)) (reverse (cdr (reverse c))))
                                                              (let ([end (car (last-pair c))])
                                                                (or (not (design-tokens-test/css:prefix? "--" end)) (design-tokens-test/css:prefix? "--tuna-" end)))))))))
                                         seven)]
                            [extra (filter (lambda (d) (not (or (assoc (car d) seven) (string=? (car d) "text-decoration-skip-ink")))) ds)])
                       (if (and (null? bad) (null? extra)) acc (cons (list file (design-tokens-test/css:rule-selector r) (map car bad) (map car extra)) acc)))))
               '() (design-tokens-test/css:file-rules file)))
           face-stylesheets))))

(test "a family's member reads its own token, then its family's, then the default; a dired face its own"
  (check-equal? '("--faces-keyword-return-font-weight" "--faces-keyword-font-weight" "revert-layer")
    (rule-chain "faces/faces.css" "keyword.return" "font-weight"))
  (check-equal? '("--faces-keyword-return-color" "--faces-keyword-color" "--tuna-violet-11") (rule-chain "faces/faces.css" "keyword.return" "color"))
  (check-equal? '("--faces-error-font-weight" "--tuna-font-weight-bold") (rule-chain "faces/faces.css" "error" "font-weight"))
  (check-equal? '("--dired-header-color" "--tuna-text") (rule-chain "dired/dired.css" "dired.header" "color")))

(test "faces that follow another face read its tokens after their own"
  (check-equal? '(("--faces-boolean-font-style" "--faces-constant-font-style" "revert-layer")
                  ("--faces-character-font-style" "--faces-constant-font-style" "revert-layer")
                  ("--faces-string-special-symbol-font-style" "--faces-constant-font-style" "revert-layer")
                  ("--faces-string-documentation-font-style" "--faces-comment-documentation-font-style" "--faces-comment-font-style" "revert-layer")
                  ("--faces-variable-parameter-font-style" "--faces-variable-definition-font-style" "--faces-variable-font-style" "revert-layer")
                  ("--faces-function-method-call-font-style" "--faces-function-call-font-style" "--faces-function-font-style" "revert-layer")
                  ("--faces-type-builtin-font-style" "--faces-type-font-style" "revert-layer")
                  ("--faces-constructor-font-style" "--faces-type-font-style" "revert-layer")
                  ("--faces-function-builtin-font-style" "--faces-builtin-font-style" "revert-layer")
                  ("--faces-label-font-style" "--faces-keyword-font-style" "revert-layer"))
    (map (lambda (f) (rule-chain "faces/faces.css" f "font-style"))
         '("boolean" "character" "string.special.symbol" "string.documentation" "variable.parameter" "function.method.call" "type.builtin"
           "constructor" "function.builtin" "label"))))

(test "a face's own default stops its family's"
  (check-equal? '(("--faces-function-method-call-color" "--faces-function-call-color" "--tuna-blue-11")
                  ("--faces-keyword-directive-color" "--tuna-pink-11"))
    (map (lambda (f) (rule-chain "faces/faces.css" f "color")) '("function.method.call" "keyword.directive"))))

(test "the defaults that follow Emacs: bold errors, warnings and successes; raw text and key bindings in the code font; bold headings; a struck strike-through"
  (check-equal? '(("--faces-error-font-weight" "--tuna-font-weight-bold") ("--faces-warning-font-weight" "--tuna-font-weight-bold")
                  ("--faces-success-font-weight" "--tuna-font-weight-bold")
                  ("--faces-markup-heading-3-font-weight" "--faces-markup-heading-font-weight" "--tuna-font-weight-bold"))
    (map (lambda (f) (rule-chain "faces/faces.css" f "font-weight")) '("error" "warning" "success" "markup.heading.3")))
  (check-equal? '(("--faces-markup-raw-font-family" "--tuna-font-code") ("--faces-markup-raw-block-font-family" "--faces-markup-raw-font-family" "--tuna-font-code")
                  ("--faces-key-binding-font-family" "--tuna-font-code"))
    (map (lambda (f) (rule-chain "faces/faces.css" f "font-family")) '("markup.raw" "markup.raw.block" "key-binding")))
  (check-equal? '(("--faces-key-binding-color" "--tuna-info") ("--faces-key-binding-background" "revert-layer"))
    (list (rule-chain "faces/faces.css" "key-binding" "color") (rule-chain "faces/faces.css" "key-binding" "background-color")))
  (check-equal? '("--faces-markup-strikethrough-text-decoration" "line-through") (rule-chain "faces/faces.css" "markup.strikethrough" "text-decoration"))
  (check-equal? '(("--faces-markup-heading-1-color" "--faces-markup-heading-color" "--tuna-blue-11")
                  ("--faces-markup-heading-6-color" "--faces-markup-heading-color" "--tuna-blue-11"))
    (map (lambda (n) (rule-chain "faces/faces.css" (format "markup.heading.~a" n) "color")) '(1 6))))

(test "a background is background-color, never the shorthand, so views' hover overlay survives"
  (check-equal? '() (filter (lambda (r) (assoc "background" (design-tokens-test/css:rule-declarations r))) (apply append (map design-tokens-test/css:file-rules face-stylesheets)))))

(test "a node a match covers is no face rule: it stays in defaults, reading the match faces' background tokens"
  (check-equal? '(("defaults" ".view .node[data-face=\"match\"] > *" "var(--faces-match-background, var(--tuna-match))")
                  ("defaults" ".view .node[data-face=\"match.other\"] > *" "var(--faces-match-other-background, var(--tuna-match-other))"))
    (map (lambda (r) (list (design-tokens-test/css:rule-layer r) (design-tokens-test/css:rule-selector r) (cdar (design-tokens-test/css:rule-declarations r))))
         (filter (lambda (r) (and (design-tokens-test/css:search (design-tokens-test/css:rule-selector r) "data-face" 0) (not (face-rule? r)))) faces-rules))))

(test "views has no rule giving the region's band way to a span above it, and chat's diff lines take their backgrounds from the diff faces alone"
  (check-equal? '() (filter (lambda (r) (design-tokens-test/css:search (design-tokens-test/css:rule-selector r) "above-region:not" 0)) (design-tokens-test/css:file-rules "views/views.css")))
  (check-equal? '() (filter (lambda (r) (member (design-tokens-test/css:rule-selector r) '(".chat-added" ".chat-removed"))) (design-tokens-test/css:file-rules "chat/chat.css"))))
