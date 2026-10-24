;;; The page: general machinery for plugins that need the browser page
;;; showing the editor, provided by the web transport
;;; (docs/briefs/2026-10-voice-dictation.md). It knows nothing about what
;;; a plugin does with the page; the microphone plugin is its first user.
;;;
;;; - A page script: a plugin adds an ES module file of its own to every
;;;   page (`add-script`), as it adds stylesheets. The page loads it as a
;;;   module, so it may import "datastar" and define Datastar actions;
;;;   files beside it (another module, such as an AudioWorklet's) are
;;;   served under the same URL prefix, so URLs relative to its
;;;   `import.meta.url` reach them. It leaves the page's head when its
;;;   plugin turns off; a module a page already ran stays loaded until
;;;   that page reloads.
;;; - A page address: a plugin receives what its page script posts to
;;;   /plugin/<plugin>/<name> (`context-add-page-address!`). The post must
;;;   name its tab in a `Tuna-Tab` header and pass the transport's Host
;;;   and Origin checks; its handler is called with the tab's client and
;;;   the body's bytes on the request's own thread, never the editor
;;;   thread, so it may not touch editor state: it hands work on through
;;;   a result poster or a thread of its own.
;;; - A page instruction: a plugin asks one client's page, once, to run a
;;;   Datastar action with an argument, after that client's next screen
;;;   (`page-instruct!`), as the clipboard copy does.
;;;
;;; Each registration belongs to the registering plugin's context and goes
;;; away when that plugin turns off.
prelude: :gerbil/core

(import :std/interface
        :std/source
        :std/string/path
        :tuna/kernel
        (only-in :tuna/plugins/clients/contract client))
(export (interface-out Page)
        page-service
        add-script
        context-add-page-address!
        page-instruct!)

(interface Page
  ;; Add the module at PATH, an absolute path, to every page, for CTX's
  ;; plugin. Raises when the file cannot be read.
  (add-script! (ctx : context) (path : :string)) => :void
  ;; Call HANDLER with (client bytes) for each post to
  ;; /plugin/<CTX's plugin>/<NAME>.
  (add-address! (ctx : context) (name : :string) (handler : :procedure)) => :void
  ;; Have C's page run the Datastar action ACTION with ARGUMENT, any value
  ;; JSON can write, once, after C's next screen.
  (instruct! (c : client) (action : :string) (argument : :t)) => :void)

(def page-service
  (new-service 'page is-Page? tier: 'startup
               doc: "Adds plugins' scripts to the browser page, takes their posts, and sends one-time instructions."))

(def (resolve-script-path (path : :string) (directory :? :string)) => :string
  (cond
   ((path-absolute? path) path)
   (directory (path-expand path directory))
   (else (error "A script path in code without a source file must be absolute" path))))

(def (add-script! (ctx : context) (path : :string) (directory :? :string)) => :void
  (with-service-provider (provider page-service Page)
    (Page-add-script! provider ctx (resolve-script-path path directory))))

(begin-syntax
  ;; The directory of the file holding STX, or #f without one.
  (def (form-directory stx)
    (let (file (stx-source-file stx))
      (and (string? file) (path-expand (path-directory file))))))

;; (add-script "microphone.js") in a plugin body, or (add-script ctx
;; "microphone.js") in a callback; a relative path resolves against the
;; directory of the file holding the form.
(defsyntax (add-script stx)
  (syntax-case stx ()
    ((_ ctx path)
     (with-syntax ((directory (form-directory stx)))
       #'(add-script! ctx path 'directory)))
    ((_ path)
     (with-syntax ((directory (form-directory stx)))
       #'(add-script! (current-context) path 'directory)))))

;; Receive the posts to /plugin/<CTX's plugin>/<NAME> with HANDLER, a
;; procedure of the posting tab's client and the body's bytes, called on
;; the request's thread. NAME is letters, digits and hyphens.
(def (context-add-page-address! (ctx : context) (name : :string) (handler : :procedure)) => :void
  (with-service-provider (provider page-service Page)
    (Page-add-address! provider ctx name handler)))

;; Have C's page run the Datastar action ACTION (letters and digits) with
;; ARGUMENT once, after C's next screen.
(def (page-instruct! (c : client) (action : :string) (argument : :t)) => :void
  (with-service-provider (provider page-service Page)
    (Page-instruct! provider c action argument)))
