;;; The renderer service (ADR 7): editor state to a screen. The screen is
;;; the layout drawn from the frame (ADR 13): everything on it, the
;;; minibuffer, the echo area and help included, is a buffer in a view.
;;; This module also holds the settings renderers read.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        (only-in :tuna/plugins/clients/contract client)
        :tuna/plugins/settings/contract
        :tuna/plugins/buffers/contract)
(export (interface-out Renderer)
        renderer-service
        html-for-each
        html->string
        show-status-line
        face-remapping
        remapped-face
        status-line-text)

;; HTML drawn already (ADR 17): its UTF-8 bytes, as a u8vector, or a
;; vector of HTML read in order, so a part drawn once is referred to, never
;; copied. It is never changed once made: frames and tabs share its parts.
(interface Renderer
  ;; Render the current editor state, as client C's browser shows it (C #f
  ;; for none; ADR 16), as HTML whose root element has the id "screen".
  ;; Each view is drawn from what C's browser measured of it, with the
  ;; newest placement sent to C. Runs on the baton.
  (render-screen (c :? client)) => :t)

(def renderer-service
  (new-service 'renderer is-Renderer? tier: 'live
               doc: "Turns editor state into a screen."))

;; Call WRITE with each u8vector of HTML H, in order.
(def (html-for-each (write : :procedure) (h : :t)) => :void
  (if (u8vector? h)
    (write h)
    (vector-for-each (lambda (part) (html-for-each write part)) h)))

;; HTML H as one string.
(def (html->string (h : :t)) => :string
  (let (size 0)
    (html-for-each (lambda ((bytes : :u8vector)) (set! size (fx+ size (u8vector-length bytes)))) h)
    (let ((out (make-u8vector size))
          (at 0))
      (html-for-each (lambda ((bytes : :u8vector))
                       (subu8vector-move! bytes 0 (u8vector-length bytes) out at)
                       (set! at (fx+ at (u8vector-length bytes))))
                     h)
      (utf8->string out))))

;; Emacs's `mode-line-format` set to nil, for a buffer: the minibuffer's
;; and the echo area's views have no status line.
(defsetting show-status-line #t
  "Whether views of this buffer show a status line under it.")

;; Emacs's `face-remapping-alist`.
(defsetting face-remapping []
  "An alist from face names to the face names drawn in their place.")

;; The face drawn for FACE in buffer B, through B's face-remapping.
(def (remapped-face (face : :symbol) (b : buffer)) => :symbol
  (let (pair (assq face (buffer-local-value face-remapping b)))
    (if pair (cdr pair) face)))

;; The text of the status line (Emacs's mode line) of view V: the buffer,
;; the line and column of V's point, and COMMAND, the running task's name,
;; if any: renderers pass it for the selected view.
(def (status-line-text (v : view) (command :? :symbol)) => :string
  (let (n (view-node v))
    (string-append
     "Tuna · " (buffer-name (view-showing v))
     (if n
       (let* ((t (text-node-content n))
              (p (view-point v)))
         (string-append " · line " (number->string (text-line-at t p))
                        ", column " (number->string (text-column t p))))
       "")
     (if command
       (string-append " · running " (symbol->string command))
       ""))))
