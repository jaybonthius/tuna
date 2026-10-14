;;; The config-blocks plugin: keeps each config: block of init.ss on while
;;; its plugin is on (docs/briefs/2026-10-configuration.md). When a
;;; block's plugin turns on, its block turns on after it; when it turns
;;; off, so does its block, which turns on again if the plugin was only
;;; restarted. Lifecycle callbacks may not turn plugins on or off, so a
;;; change is not made in the callback: while the editor loop runs it is
;;; queued as a task; while the loop is stopped, or while the start-up
;;; or reload code (tuna/boot.ss) is changing plugins, it is recorded, and
;;; that code makes it after each change.
prelude: :gerbil/core

(import :tuna/kernel
        :tuna/lib/configuration)
(export block-follower
        block-follower-hooks
        new-block-follower
        follow-declarations!
        defer-block-syncs!
        take-pending-block-syncs!)

;; The config-blocks plugin for the running configuration (HOOKS, set
;; once it is made); the declarations whose blocks it keeps, which a
;; reload replaces; the names of the plugins whose blocks must be brought
;; in line, newest first; and whether changes are recorded rather than
;; queued as tasks.
(defclass block-follower ((hooks        :? plugin)
                          (declarations : :list)
                          (pending      : :list)
                          (deferring?   : :boolean))
  final: #t)

(def (new-block-follower (declarations : :list)) => block-follower
  (let (self (block-follower hooks: #f declarations: declarations pending: [] deferring?: #f))
    (def (follow! (name : :symbol))
      (cond
       ((and (editor-loop-running?) (not (block-follower-deferring? self)))
        (spawn-task! 'config-block
                     (lambda ()
                       (let (d (declaration-named self name))
                         (when d (sync-block! d)))))
        (void))
       ((not (memq name (block-follower-pending self)))
        (set! (block-follower-pending self) (cons name (block-follower-pending self))))))
    (defplugin config-blocks
      "Keeps each config: block of init.ss on while its plugin is on."
      optional: [messages-service]
      (let (ctx (current-context))
        (context-add-hook! ctx plugin-activated-hook 'config-blocks
                           (lambda ((p : plugin))
                             (let (d (declaration-named self (plugin-name p)))
                               (when (and d (not (plugin-active? (: (declaration-block d) plugin))))
                                 (follow! (plugin-name p))))))
        (context-add-hook! ctx plugin-deactivated-hook 'config-blocks
                           (lambda ((p : plugin))
                             (when (declaration-named self (plugin-name p))
                               (follow! (plugin-name p)))))))
    (set! (block-follower-hooks self) config-blocks)
    self))

;; Keep the blocks of DECLARATIONS from now on.
(def (follow-declarations! (f : block-follower) (declarations : :list)) => :void
  (set! (block-follower-declarations f) declarations))

;; While DEFER? is true, record block changes for take-pending-block-syncs!
;; even while the editor loop runs.
(def (defer-block-syncs! (f : block-follower) (defer? : :boolean)) => :void
  (set! (block-follower-deferring? f) defer?))

;; The declarations whose blocks the start-up or reload code must sync,
;; oldest first; asking clears them.
(def (take-pending-block-syncs! (f : block-follower)) => :list
  (let (names (reverse (block-follower-pending f)))
    (set! (block-follower-pending f) [])
    (filter-map (cut declaration-named f <>) names)))

;; The declaration with a block for the plugin named NAME, or #f.
(def (declaration-named (f : block-follower) (name : :symbol)) => (Maybe declaration)
  (find (lambda ((d : declaration))
          (and (declaration-block d) (eq? (plugin-name (declaration-target d)) name)))
        (block-follower-declarations f)))

;; Turn D's block off, then on again if its plugin is on.
(def (sync-block! (d : declaration)) => :void
  (let ((parent (declaration-target d))
        (block (: (declaration-block d) plugin)))
    (deactivate-plugin! block)
    (when (plugin-active? parent)
      (with-catch (lambda (e)
                    (message (string-append "The config: block of "
                                            (symbol->string (plugin-name parent))
                                            (if (declaration-source d)
                                              (string-append " (" (declaration-source d) ")")
                                              "")
                                            " failed and is off: " (exception-summary e))))
                  (lambda () (activate-plugin! block))))))
