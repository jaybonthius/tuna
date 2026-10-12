;;; The kernel's public facade (ADR 12). Plugins import only this and the
;;; facades of the services they use.
prelude: :gerbil/core

(import ./kernel/ids
        ./kernel/entries
        ./kernel/state
        ./kernel/plugins
        ./kernel/hooks
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
        (except-out (import: ./kernel/plugins) run-lifecycle-hook)
        hook
        hook?
        hook-name
        hook-doc
        new-hook
        hook-callback-names
        (import: ./kernel/loop))
