;;; The microphone: capturing the audio of a client's microphone
;;; (docs/briefs/2026-10-voice-dictation.md). The microphone is the
;;; browser's, so its page captures it, while the server says when.
;;;
;;; Audio comes as raw samples: float32 little-endian, mono, at
;;; `microphone-sample-rate` samples a second, in chunks of about a tenth
;;; of a second, in order. Chunks go to the capture's chunk callback on
;;; the thread that received them, never the editor thread, so audio
;;; never waits for the editor and the callback may not touch editor
;;; state. When capture cannot start or ends on its own (the browser
;;; refused the microphone, the page has none, the tab went away), the
;;; failure callback gets a sentence saying why, once, on the editor
;;; thread, and the capture is over.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        (only-in :tuna/plugins/clients/contract client))
(export (interface-out Microphone)
        microphone-service
        microphone-sample-rate
        microphone-start!
        microphone-stop!)

(def microphone-sample-rate 16000)

(interface Microphone
  (start! (c : client) (on-chunk : :procedure) (on-failure : :procedure)) => :void
  (stop! (c : client)) => :void)

(def microphone-service
  (new-service 'microphone is-Microphone? tier: 'live
               doc: "Captures a client's microphone as raw audio."))

;; Start capturing C's microphone: ON-CHUNK receives each chunk's bytes
;; (off the editor thread), ON-FAILURE a sentence saying why capture
;; could not start or stopped on its own (on the editor thread). A
;; capture already running on C is replaced; its callbacks get nothing
;; more. Call on the editor thread.
(def (microphone-start! (c : client) (on-chunk : :procedure) (on-failure : :procedure)) => :void
  (with-service-provider (provider microphone-service Microphone)
    (Microphone-start! provider c on-chunk on-failure)))

;; Stop capturing C's microphone; its callbacks get nothing more. Call on
;; the editor thread.
(def (microphone-stop! (c : client)) => :void
  (with-service-provider (provider microphone-service Microphone)
    (Microphone-stop! provider c)))
