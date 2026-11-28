(library (tuna)
  (export
    spawn-task fork-task suspend current-task task? task-state join-task live-tasks task-owner task-frames
    cancel-task stop-task task-request call-with-cancellation-masked
    &cancelled make-cancelled cancelled? cancelled-reason
    current-owner call-as-owner owner? owner-name owner-live? module-owner owner<? make-owner made-owner
    unload-owner! on-unload owner-unloading owner-changes loaded-modules
    &unloaded unloaded? unloaded-owner
    define-public advice-add! advice-remove! override-set! override-remove!
    changeable? definition-changes definition-documentation
    load-module! reload-modules! eval-in-module module-file
    report report-owner tick batch-ended module-loaded exit-anyway?)
  (import (tuna conditions) (tuna kernel) (tuna modules)))
