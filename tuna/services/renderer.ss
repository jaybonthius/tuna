;;; The renderer service (ADR 7): editor state to a screen.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel)
(export (interface-out Renderer)
        renderer-service)

(interface Renderer
  ;; Render the current editor state as an HTML fragment whose root element
  ;; has the id "screen". Runs on the baton.
  (render-screen) => :string)

(def renderer-service
  (new-service 'renderer is-Renderer? tier: 'live
               doc: "Turns editor state into a screen."))
