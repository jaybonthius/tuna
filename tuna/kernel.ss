;;; The kernel's public facade (ADR 12, "Kernel contract"). Plugins,
;;; contracts, and libraries import only this. Every export is listed here,
;;; under the ADR 12 item it belongs to; the kernel object itself stays
;;; private, so nothing outside the kernel selects or holds a kernel.
prelude: :gerbil/core

(import ./kernel/ids
        ./kernel/entries
        ./kernel/state
        ./kernel/plugins
        ./kernel/hooks
        ./kernel/loop)
(export
  ;; 1. Plugin runtime: plugins, contexts and receipts, owner-tagged
  ;; entries, activation, services with providers and adapting dependents.
  plugin                                ; the type, for annotations
  plugin-name                           ; lifecycle hooks pass plugins
  plugin-doc
  plugin-source
  defplugin
  context
  current-context
  context-defer!
  context-add-entry!
  entry
  entry-owner
  entry-value
  entry-serial
  entry-doc
  entry-source
  entry-table
  new-entry-table
  entry-table-ref
  entry-table-entries
  entry-table-names
  service                               ; the type, for annotations
  service-name                          ; service-changed-hook passes services
  new-service
  service-provider
  context-provide!
  context-adapt!
  activate-plugin!
  deactivate-plugin!
  plugin-active?
  deactivate-all-plugins!
  describe-services
  service-info
  service-info-name
  service-info-tier
  service-info-provider
  service-info-dependents
  service-info-adapting
  service-info-doc
  (phi: +1 stx-source-string)           ; for registration macros that record their source

  ;; 2. Execution rules: the editor loop and its baton, tasks, yield
  ;; points, the quit lane, the input queue, and posting results.
  start-editor-loop!
  stop-editor-loop!
  editor-loop-running?
  input-submitter
  call-on-editor-loop
  spawn-task!
  cancel-task!
  running-task
  current-task-id
  current-task-name
  result-poster
  suspend
  resume!
  resume-quit!
  input-pending?                        ; ADR 12 lists it
  discard-input                         ; ADR 12 lists it
  check-quit
  signal-quit
  with-inhibit-quit                     ; ADR 3's inhibit-quit
  quit-condition?
  redisplay

  ;; 3. Hooks and identities.
  new-hook
  context-add-hook!
  run-hook
  plugin-activated-hook                 ; the kernel's lifecycle hooks, which ADR 12 lists
  plugin-deactivated-hook
  service-changed-hook
  task-started-hook
  task-finished-hook
  next-id!

  ;; 4. Consumed seams: the services the kernel calls.
  Input
  Input-arrival
  Input-resolve!
  input-service
  Display
  display-service
  Messages
  messages-service
  message
  exception-summary)
