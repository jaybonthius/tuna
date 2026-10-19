;;; The design-tokens plugin: its variant: option accepts only shipped
;;; variants, checked when init.ss loads; it registers the variant's file
;;; as (design-tokens tokens) with the file's text; and the file defines
;;; every token agents/guides/design-tokens.md lets plugins use.
(import :std/misc/ports
        :std/source
        :std/test
        :tuna/kernel
        :tuna/boot
        :tuna/plugins/stylesheets/contract
        :tuna/plugins/design-tokens/plugin
        "../../../../tuna/tests/support/kernel")
(export design-tokens-test)

(def tokens-directory
  (path-normalize (path-expand "../../tokens" (path-expand (this-source-directory)))))

(def (call-with-temporary-directory proc)
  (let (directory (path-expand (string-append "tuna-design-tokens-test-"
                                              (number->string (random-integer 1000000000)))
                               (getenv "TMPDIR" "/tmp")))
    (create-directory* directory)
    (try
     (proc directory)
     (finally (delete-file-or-directory directory #t)))))

;; The problems `tuna check` reports for an init.ss whose line 3 is LINE,
;; or #f.
(def (check-init (directory : :string) (line : :string)) => :t
  (let (path (path-expand "init.ss" directory))
    (write-file-string path (string-append "#lang :tuna/config\n"
                                           "(import :tuna/plugins/design-tokens/plugin)\n"
                                           line "\n"))
    (check-configuration (make-config-choice path "--config"))))

;; The documented subset, by its naming patterns.
(def (documented-tokens) => :list
  (def (steps (from : :fixnum) (to : :fixnum)) => :list
    (let lp ((n to) (acc []))
      (if (< n from) acc (lp (- n 1) (cons (number->string n) acc)))))
  (def (scale (prefix : :string) (from : :fixnum) (to : :fixnum)) => :list
    (map (lambda (n) (string-append prefix n)) (steps from to)))
  (append
   (apply append
          (map (lambda (palette)
                 (apply append
                        (map (lambda (n)
                               (map (lambda (suffix) (string-append "--" palette "-" n suffix))
                                    ["" "-on" "-dim"]))
                             (steps 1 12))))
               ["primary" "secondary" "tertiary" "neutral" "neutral-variant" "error"]))
   (scale "--size-" -2 12)
   (scale "--font-size-" -2 12)
   (scale "--font-line-height-" -3 4)
   (scale "--border-width-" 0 5)
   (scale "--border-radius-" 0 6)
   (scale "--shadow-" -4 6)
   (map (lambda (name) (string-append "--font-" name)) ["sans" "serif" "mono"])
   (map (lambda (name) (string-append "--font-weight-" name))
        ["thin" "extra-light" "light" "normal" "medium" "semi-bold" "bold" "extra-bold" "black"
         "extra-black"])
   (map (lambda (name) (string-append "--anim-duration-" name))
        ["none" "instant" "fast" "base" "slow" "long"])
   (map (lambda (name) (string-append "--anim-ease-" name))
        ["standard" "emphasized" "entrance" "linear"])
   (map (lambda (name) (string-append "--code-" name))
        ["bg" "fg" "inner-bg" "border" "border-subtle" "selection" "highlight-line" "ln" "ln-current"
         "comment" "comment-special" "keyword" "keyword-const" "keyword-decl" "keyword-namespace"
         "name" "name-attribute" "name-builtin" "name-class" "name-constant" "name-decorator"
         "name-entity" "name-exception" "name-function" "name-label" "name-namespace"
         "name-property" "name-tag" "name-variable"
         "string" "string-affix" "string-delim" "string-doc" "string-escape" "string-regex"
         "number" "operator" "type" "error" "deleted" "inserted" "emph" "strong"])))

(def design-tokens-test
  (test-suite "tuna/plugins/design-tokens"
    (test-case "variant: accepts only a shipped variant, checked when init.ss loads"
      (check design-token-variants => '(stellar-default))
      (for-each (lambda (variant)
                  (check (file-exists? (path-expand (string-append (symbol->string variant) ".css")
                                                    tokens-directory))
                         => #t))
                design-token-variants)
      (call-with-temporary-directory
       (lambda (directory)
         (check (check-init directory "(use-plugin design-tokens variant: stellar-default)") => #f)
         (check (check-init directory "(use-plugin design-tokens)") => #f)
         (let (problem (check-init directory "(use-plugin design-tokens variant: stellar-defualt)"))
           (check (and (string-contains
                        problem
                        "init.ss line 3: design-tokens option variant must be one of: stellar-default")
                       #t)
                  => #t)))))

    (test-case "the plugin adds its variant's file as (design-tokens tokens)"
      (call-with-fresh-kernel [design-tokens]
        (lambda ()
          (let (sheets (stylesheets))
            (check (length sheets) => 1)
            (let (s (car sheets))
              (check [(stylesheet-owner s) (stylesheet-name s)] => '(design-tokens tokens))
              (check (stylesheet-path s) => (path-expand "stellar-default.css" tokens-directory))
              (check (stylesheet-warning s) => #f)
              (check (stylesheet-text s) => (read-file-string (stylesheet-path s))))))))

    (test-case "the file defines every token plugins may use"
      (let (text (read-file-string (path-expand "stellar-default.css" tokens-directory)))
        (for-each (lambda (name)
                    (check [name (and (string-contains text (string-append name ":")) #t)] => [name #t]))
                  (documented-tokens))))))
