#!/usr/bin/env gxi

(import :std/make :std/source)

(def workspace-directory (path-expand (this-source-directory)))

;; Where gerbil-libghostty is: its source, linked or cloned into the
;; workspace's packages, and its native library, which its build staged
;; under GERBIL_PATH. A program (the terminal helper) is linked statically,
;; so its build compiles the binding's C again and needs the binding's
;; own headers, not only the staged ones.
(def libghostty-source
  (or (getenv "GERBIL_LIBGHOSTTY" #f)
      (path-expand "pkg/gerbil-libghostty" (gerbil-path))))
(def libghostty-native (path-expand "lib/gerbil-libghostty/native" (gerbil-path)))

;; Where gerbil-md4c is. md4c is compiled into its foreign module, so the
;; statically linked tuna program, which links the markdown plugin through
;; the starter configuration, compiles that C again from md4c's sources.
(def md4c-source
  (or (getenv "GERBIL_MD4C" #f)
      (path-expand "pkg/gerbil-md4c" (gerbil-path))))

;; One make call per gerbil.pkg, with specs relative to that package.
;; This order follows package imports, not runtime service requirements.
(def packages
  `(("tuna"
     "version"
     "kernel/ids" "kernel/entries" "kernel/state" "kernel/tasks"
     "kernel/plugins" "kernel/hooks" "kernel/loop" "kernel"
     "lib/plain-data" "lib/timers" "lib/jobs" "lib/background" "lib/plugin-options" "lib/configuration" "lib/advice" "lib/memo"
     "lib/unix" "lib/helper-processes"
     "configuration" "prelude" "config" "plugin-use" "config-blocks"
     (gxc: "boot" (extra-inputs: ("../starter/init.ss")))
     "control"
     (exe: "main" bin: "tuna"
           "-cc-options" ,(string-append "-I" (path-expand "native" md4c-source))))
    ("plugins/clients" "contract")
    ("plugins/commands" "contract" "plugin")
    ("plugins/stylesheets" "contract" "plugin")
    ("plugins/settings" "contract" "plugin")
    ("plugins/text-store" "contract" "plugin")
    ("plugins/session" "contract" "plugin")
    ("plugins/buffers" "contract" "plugin")
    ("plugins/keys" "contract" "plugin")
    ("plugins/layout" "contract" "tree" "plugin")
    ("plugins/renderer" "contract" "plugin")
    ("plugins/echo-area" "contract" "plugin")
    ("plugins/buttons" "contract" "plugin")
    ("plugins/markdown" "contract" "faces" "style" "nodes" "plugin")
    ("plugins/editing" "contract" "words" "mouse" "plugin")
    ("plugins/minibuffer" "contract" "plugin")
    ("plugins/completion" "contract" "plugin")
    ("plugins/help" "contract" "describe-advice" "describe-stylesheets" "plugin")
    ("plugins/completion-list" "plugin")
    ("plugins/view-commands" "plugin")
    ("plugins/scrolling" "plugin")
    ("plugins/configuration" "plugin")
    ("plugins/proced" "plugin")
    ("plugins/web" "contract" "embed" "proxy"
     (gxc: "plugin"
           (extra-inputs: ,(map (cut string-append "web/" <>)
                               (filter (lambda ((name : :string))
                                         (eq? (file-info-type (file-info (path-expand name "plugins/web/web")))
                                              'regular))
                                       (directory-files "plugins/web/web"))))))
    ("plugins/profiler" "clock" "spans" "sampler" "plugin")
    ("plugins/files" "contract" "encoding" "line-diff" "watcher" "local-disk" "picker" "plugin")
    ("plugins/autosave" "plugin")
    ("plugins/terminal"
     "io"
     "protocol"
     "connection"
     "saved-screen"
     "contract"
     "keys"
     "screen"
     "copy-text"
     "links"
     "plugin"
     ;; The helper links libghostty-vt where gerbil-libghostty staged it,
     ;; by a path relative to the program.
     (exe: "helper" bin: "tuna-terminal-helper"
           "-cc-options" ,(string-append "-std=gnu11 -I" (path-expand "native" libghostty-source)
                                         " -I" (path-expand "include" libghostty-native))
           "-ld-options" ,(string-append "-L" (path-expand "lib" libghostty-native)
                                         " -lghostty-vt -Wl,-rpath,$ORIGIN/../lib/gerbil-libghostty/native/lib")))
    ("plugins/program-status" "contract" "plugin")
    ("plugins/notifications" "plugin")
    ("plugins/pi" "jsonl" "replay" "tool-text" "contract" "connection" "transcript" "plugin"
     (exe: "helper" bin: "tuna-pi-helper"))
    ("plugins/microphone" "contract" "plugin")
    ("plugins/voice" "contract" "spoken" "plugin")))

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
