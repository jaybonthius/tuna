#lang :tuna/prelude
;;; Design tokens: the raw scale (palettes, sizes, fonts, radii, shadows,
;;; motion) as one stylesheet, (design-tokens tokens), first on the page
;;; when init.ss declares this plugin first. The variant: option picks one
;;; of the pregenerated files in tokens/; agents/guides/design-tokens.md
;;; names the tokens other plugins may use.
;;;
;;; tokens/stellar-default.css is Stellar's output for
;;; tokens/stellar.config.json; `make tokens` regenerates it with the
;;; owner's Stellar binary, which is not in this repository and is never
;;; needed to build or run Tuna.
(import :tuna/kernel
        :tuna/lib/plugin-options
        :tuna/plugins/stylesheets/contract)
(export design-tokens
        design-token-variants)

;; The shipped variants, each tokens/<variant>.css.
(def design-token-variants '(stellar-default))

(def variant-type
  (make-option-type (string-append "one of: "
                                   (string-join (map symbol->string design-token-variants) ", "))
                    (lambda (value) (and (memq value design-token-variants) #t))
                    string->symbol))

(defplugin (design-tokens ctx)
  "Adds the design tokens stylesheet that the variant: option names."
  (add-stylesheet 'tokens (string-append "tokens/"
                                         (symbol->string (plugin-option design-tokens 'variant))
                                         ".css")))

(defplugin-options design-tokens
  (variant 'stellar-default "Which shipped design tokens file to use." variant-type))
