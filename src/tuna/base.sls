(library (tuna base)
  (export
    define-public
    current-owner
    as-module
    definition-changes
    module-changes
    eval-in-module
    load-module!
    unload-module!
    loaded-modules
    on-unload
    advice-add!
    advice-remove!
    remove-override!
    post!
    request-quit!
    &quit
    quit-condition?
    report
    tick
    batch-ended
    module-loaded
    module-failed)
  (import (tuna core changes) (tuna core definitions) (tuna core modules) (tuna core main-thread)))
