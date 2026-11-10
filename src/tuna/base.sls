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
    module-loaded)
  (import (tuna core changes) (tuna core definitions) (tuna core modules) (tuna core main-thread)))
