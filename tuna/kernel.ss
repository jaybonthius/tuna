;;; The kernel's public facade (ADR 12). Plugins import only this and the
;;; facades of the services they use.
prelude: :gerbil/core

(import ./kernel/ids
        ./kernel/entries
        ./kernel/state
        ./kernel/plugins
        ./kernel/loop)
(export (import: ./kernel/ids)
        (struct-out entry)
        entry-table
        entry-table?
        new-entry-table
        entry-table-ref
        entry-table-entries
        entry-table-keys
        kernel
        kernel?
        new-kernel
        current-kernel
        exception-summary
        (import: ./kernel/plugins)
        (import: ./kernel/loop))
