;;; The help panel (live tier): holds the latest help output for renderers.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        :tuna/services/help)
(export help-panel-plugin)

(defclass help-panel ((output :? help-output))
  final: #t)

(implement Help help-panel
  (show-help! (lambda (self output) (set! self.output output)))
  (current-help (lambda (self) self.output)))

(defplugin (help-panel-plugin ctx)
  "Shows help output in a panel above the buffer."
  (context-provide! ctx help-service (Help (help-panel output: #f))))
