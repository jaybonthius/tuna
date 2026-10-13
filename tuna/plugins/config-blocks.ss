;;; The config-blocks plugin: keeps each config: block of init.ss on while
;;; its plugin is on (docs/briefs/2026-10-configuration.md). When a
;;; block's plugin turns on, its block turns on after it; when it turns
;;; off, so does its block, which turns on again if the plugin was only
;;; restarted. Lifecycle callbacks may not turn plugins on or off, so a
;;; change is not made in the callback: while the editor loop runs it is
;;; queued as a task; before then it is recorded, and the start-up code
;;; (tuna/boot.ss) makes it after each activation.
prelude: :gerbil/core

(import :tuna/kernel
        :tuna/lib/configuration)
(export block-follower
        block-follower-hooks
        new-block-follower
        take-pending-block-syncs!)

;; The config-blocks plugin for one configuration (HOOKS, set once it is
;; made), and the declarations whose blocks the start-up code must bring
;; in line with their plugins, newest first.
(defclass block-follower ((hooks   :? plugin)
                          (pending : :list))
  final: #t)

(def (new-block-follower (declarations : :list)) => block-follower
  (let ((blocks (filter declaration-block declarations))
        (self (block-follower hooks: #f pending: [])))
    (def (follow! (d : declaration))
      (cond
       ((editor-loop-running?)
        (spawn-task! 'config-block (lambda () (sync-block! d)))
        (void))
       ((not (memq d (block-follower-pending self)))
        (set! (block-follower-pending self) (cons d (block-follower-pending self))))))
    (defplugin config-blocks
      "Keeps each config: block of init.ss on while its plugin is on."
      (let (ctx (current-context))
        (context-add-hook! ctx plugin-activated-hook 'config-blocks
                           (lambda ((p : plugin))
                             (for-each (lambda ((d : declaration))
                                         (unless (plugin-active? (: (declaration-block d) plugin))
                                           (follow! d)))
                                       (declarations-of blocks p))))
        (context-add-hook! ctx plugin-deactivated-hook 'config-blocks
                           (lambda ((p : plugin))
                             (for-each follow! (declarations-of blocks p))))))
    (set! (block-follower-hooks self) config-blocks)
    self))

;; The declarations whose blocks the start-up code must sync, oldest
;; first; asking clears them.
(def (take-pending-block-syncs! (f : block-follower)) => :list
  (let (declarations (reverse (block-follower-pending f)))
    (set! (block-follower-pending f) [])
    declarations))

(def (declarations-of (declarations : :list) (p : plugin)) => :list
  (filter (lambda ((d : declaration)) (eq? (plugin-name (declaration-target d)) (plugin-name p)))
          declarations))

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
