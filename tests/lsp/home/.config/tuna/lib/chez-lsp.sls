#!tuna
;; A plugin of its own that defines a server, as a language's plugin would.
(import (lsp))

(lsp:define-server chez-lsp '("chez-lsp" "--stdio"))
