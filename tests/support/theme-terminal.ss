;;; theme-terminal: a demo theme with a flat, monospace, terminal-like
;;; look. It only replaces other plugins' stylesheets (the files are in
;;; theme-terminal/): the page's and the renderer's semantic tokens, and
;;; completion's, which switch to the system colours Canvas and CanvasText
;;; with reverse video for what is selected, and the layout's and buttons'
;;; rules, rewritten flat with bracketed tabs and buttons. Turning it off
;;; restores every original; a replacement in init.ss still beats it. The
;;; demo toggles it with C-c T (demo/demo.ss).
prelude: :gerbil/core

(import :tuna/kernel
        :tuna/plugins/stylesheets/contract)
(export theme-terminal)

(defplugin (theme-terminal ctx)
  "A flat, monospace, terminal-like look: replaces a few plugins' stylesheets."
  (replace-stylesheet 'web-transport 'tokens "theme-terminal/page.css")
  (replace-stylesheet 'html-renderer 'tokens "theme-terminal/renderer.css")
  (replace-stylesheet 'layout 'rules "theme-terminal/layout.css")
  (replace-stylesheet 'completion-list 'tokens "theme-terminal/completion.css")
  (replace-stylesheet 'buttons 'rules "theme-terminal/buttons.css"))
