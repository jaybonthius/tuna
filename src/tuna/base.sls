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
    post!
    request-quit!
    &quit
    quit-condition?
    report
    tick
    module-loaded
    exit)
  (import (only (chezscheme) export) (tuna core changes) (tuna core definitions) (tuna core modules)
          (tuna core main-thread))
  ;; sleep would block the main thread.
  (export (import (except (chezscheme) sleep exit))))
