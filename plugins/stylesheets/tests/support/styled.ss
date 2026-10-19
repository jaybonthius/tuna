;;; Plugins that register stylesheets from css/ beside this file, for the
;;; stylesheets tests. The init.ss files those tests write import this
;;; module by its absolute path.
prelude: :gerbil/core

(import :tuna/kernel
        :tuna/plugins/stylesheets/contract)
(export styled-a styled-b theme missing-file)

(defplugin styled-a "Adds tokens and rules."
  (add-stylesheet 'tokens "css/a-tokens.css")
  (add-stylesheet 'rules "css/a-rules.css"))

(defplugin styled-b "Adds rules."
  (add-stylesheet 'rules "css/b-rules.css"))

(defplugin theme "Replaces styled-a's rules, removes styled-b's, and replaces a sheet nobody adds."
  (replace-stylesheet 'styled-a 'rules "css/theme-a-rules.css")
  (replace-stylesheet 'styled-b 'rules #f)
  (replace-stylesheet 'styled-a 'unknown "css/theme-x.css"))

(defplugin missing-file "Adds a stylesheet whose file does not exist."
  (add-stylesheet 'rules "css/no-such-file.css"))
