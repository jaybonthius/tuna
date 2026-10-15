;;; The kernel's public facade (ADR 12, "Kernel contract"). Plugins,
;;; contracts, and libraries import only this. Every export is listed here,
;;; under the ADR 12 item it belongs to; the kernel object itself stays
;;; private, so nothing outside the kernel selects or holds a kernel.
prelude: :gerbil/core

(import ./kernel/ids
        ./kernel/entries
        ./kernel/state
        ./kernel/tasks
        ./kernel/plugins
        ./kernel/hooks
        ./kernel/loop)
(export
  ;; 1. Plugin runtime: plugins, contexts and receipts, owner-tagged
  ;; entries, activation, services with one provider.
  plugin                                ; the type, for annotations
  plugin?                               ; configuration validates declarations
  plugin-name                           ; lifecycle hooks pass plugins
  plugin-doc
  plugin-source
  plugin-provides                       ; start-up checks unique service declarations
  plugin-optional                       ; start-up checks imported contracts
  plugin-requires                       ; start-up waits for, and reports, missing services
  defplugin
  context
  context-plugin-name                   ; registration diagnostics name their owner
  current-context
  call-with-context
  context-bind
  with-service-provider
  set-plugin-order!
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
  service?                              ; start-up recognizes contract exports
  new-service
  service-provider
  context-provide!
  deactivate-plugin!
  plugin-active?
  plugin-deactivation-closure
  deactivate-all-plugins!
  describe-services
  service-info
  service-info-name
  service-info-tier
  service-info-provider
  service-info-dependents
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
  call-with-task-owner
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
