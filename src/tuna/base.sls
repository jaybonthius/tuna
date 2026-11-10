(library (tuna base)
  (export
    define-public
    this-module
    as-module
    definition-changes
    module-changes
    eval-in-module
    load-module!
    unload-module!
    on-unload
    advice-add!
    advice-remove!
    report
    module-loaded)
  (import (only (chezscheme) export) (tuna core changes) (tuna core definitions) (tuna core modules))
  ;; sleep would block the main thread.
  (export (import (except (chezscheme) sleep))))
