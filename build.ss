#!/usr/bin/env gxi

(import :std/make :std/source)

(def workspace-directory (path-expand (this-source-directory)))

;; One make call per gerbil.pkg, with specs relative to that package.
;; This order follows package imports, not runtime service requirements.
(def packages
  `(("tuna"
     "version"
     "kernel/ids" "kernel/entries" "kernel/state" "kernel/tasks"
     "kernel/plugins" "kernel/hooks" "kernel/loop" "kernel"
     "lib/timers" "lib/jobs" "lib/plugin-options" "lib/configuration"
     "configuration" "prelude" "config" "config-blocks"
     (gxc: "boot" (extra-inputs: ("../starter/init.ss")))
     "control"
     (exe: "main" bin: "tuna"))
    ("plugins/commands" "contract" "plugin")
    ("plugins/settings" "contract" "plugin")
    ("plugins/text-store" "contract" "plugin")
    ("plugins/session" "contract" "plugin")
    ("plugins/buffers" "contract" "plugin")
    ("plugins/keys" "contract" "plugin")
    ("plugins/layout" "contract" "tree" "plugin")
    ("plugins/renderer" "contract" "plugin")
    ("plugins/echo-area" "contract" "plugin")
    ("plugins/help" "contract" "plugin")
    ("plugins/buttons" "contract" "plugin")
    ("plugins/basic-editing" "plugin")
    ("plugins/minibuffer" "contract" "plugin")
    ("plugins/completion" "contract" "plugin")
    ("plugins/completion-vertical" "plugin")
    ("plugins/extended-command" "plugin")
    ("plugins/orderless" "plugin")
    ("plugins/command-annotations" "plugin")
    ("plugins/view-commands" "plugin")
    ("plugins/autosave" "plugin")
    ("plugins/reload-config" "plugin")
    ("plugins/web" "embed"
     (gxc: "plugin"
           (extra-inputs: ,(map (cut string-append "web/" <>)
                               (directory-files "plugins/web/web")))))))

(def (build-options (args : :list)) => :list
  (match args
    ([] [])
    (["--release" . rest] (cons* build-release: #t (build-options rest)))
    (["--optimized" . rest] (cons* build-optimized: #t (build-options rest)))
    (["--debug" . rest] (cons* debug: #t (build-options rest)))
    (else (error "Unexpected build options" args))))

(def (build-packages (options : :list)) => :void
  (for-each (lambda ((package : :pair))
              (apply make (cdr package)
                     srcdir: (path-expand (car package) workspace-directory)
                     options))
            packages))

(def (main . args)
  (match args
    (["meta"] (write '("spec" "compile" "clean")) (newline))
    (["spec"] (pretty-print packages))
    (["clean"]
     (for-each (lambda ((package : :pair))
                 (make-clean (cdr package)
                             srcdir: (path-expand (car package) workspace-directory)))
               (reverse packages)))
    (["compile" . options] (build-packages (build-options options)))
    ([] (build-packages []))))
