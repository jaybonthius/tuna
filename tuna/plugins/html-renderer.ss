;;; HTML renderer (live tier): editor state -> SXML -> HTML (ADR 7).
prelude: :gerbil/core

(import :std/text/markup/sxml/print
        :tuna/kernel
        :tuna/services/renderer)
(export html-renderer-plugin
        screen-sxml)

(defstruct html-renderer ()
  final: #t)

;; The screen: help output when there is some, the status line, and the
;; echo area.
(def (screen-sxml) => :list
  (let ((help (current-help))
        (command (current-command-name)))
    `(main (@ (id "screen") (class "screen"))
       ,@(if help
           (using (help : help-output)
             `((section (@ (class "help") (aria-label "Help"))
                 (h1 ,help.title)
                 (pre ,(string-join help.lines "\n")))))
           [])
       (footer
        (p (@ (class "status-line"))
           "Tuna"
           ,(if command
              (string-append " · running " (symbol->string command))
              ""))
        (p (@ (class "echo-area") (role "status")) ,(current-message))))))

(def (html-string (markup : :list)) => :string
  (call-with-output-string ""
    (lambda (port) (write-sxml markup port: port xml?: #f))))

(defmethod {render-screen html-renderer}
  (lambda (self) (html-string (screen-sxml))))

(defplugin (html-renderer-plugin ctx)
  "Renders the screen as HTML."
  (context-provide! ctx renderer-service (Renderer (make-html-renderer))))
