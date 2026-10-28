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
;;;
;;; The transport also announces what happens to input and screens on
;;; their way between a tab and the editor, for anything that follows them
;;; (a sync indicator, an input log, a profiler): an input item arriving,
;;; a screen made ready for a tab, written to it, and applied by its page,
;;; with the durations the page measured on its own clock. Keys are named
;;; by (client, sequence), screens by (client, stream, count) and their
;;; revision; each screen says the last input sequence of its tab that it
;;; includes. The arrival, writing and applying hooks run on the request's
;;; or the stream's own thread, never the editor thread: their callbacks
;;; must be quick, must not touch editor state and must not fail.
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
        page-instruct!
        input-arrived-hook
        screen-ready-hook
        screen-sent-hook
        screen-applied-hook)

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

;; Arguments: the client, the item's page-load sequence number, and the
;; item (the keys contract's key, pointer, scroll or paste event). Runs on
;; the request's thread as a valid item arrives, before it waits for its
;; turn in its tab's order.
(def input-arrived-hook
  (new-hook 'input-arrived
            doc: "Runs with a client, a sequence number and an input item as the item arrives from the client's page."))

;; Arguments: the client, the revision of its new screen, or #f when its
;; screen did not change and nothing will be sent, and the last input
;; sequence of the client that the screen includes. Runs on the editor
;; thread after each redisplay, for each tab drawn.
(def screen-ready-hook
  (new-hook 'screen-ready
            doc: "Runs with a client, its new screen's revision (#f for none) and the last input it includes, after a redisplay."))

;; Arguments: the client, the stream and the screen's count on it, the
;; screen's revision, the last input sequence it includes, and the bytes
;; of HTML written. Runs on the stream's thread once the screen is
;; written, which happens only after the page applied the one before.
(def screen-sent-hook
  (new-hook 'screen-sent
            doc: "Runs with a client, stream, count, revision, last input included and bytes, once a screen is written to the client's page."))

;; Arguments: the client, the stream and count the page names, and what
;; it measured, an alist of plain data with durations in milliseconds of
;; its own clock:
;;   (revision . N) (through . S)  the screen and the last input it includes;
;;   (morph . MS)                  applying the screen's event;
;;   (settle . MS)                 from then until the page saw it applied;
;;   (keys . ((SEQ KEY-TO-SEND SEND-TO-RECEIVED) ...))
;;                                 each input of the page this screen is the
;;                                 first to include: from its event to its
;;                                 post (#f when not a key), and from its
;;                                 post to this screen arriving;
;;   (painted . ((STREAM COUNT MS) ...))
;;                                 earlier screens, each from applied to the
;;                                 frame after it was painted.
;; Any of them may be missing. A report of only a paint names the screen
;; again (its count is not newer). Runs on the request's thread.
(def screen-applied-hook
  (new-hook 'screen-applied
            doc: "Runs with a client, stream, count and the page's own measurements when its page reports a screen applied or painted."))

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
