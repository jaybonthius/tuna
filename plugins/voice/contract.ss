;;; Voice: speech turned into text as it is spoken
;;; (docs/briefs/2026-10-voice-dictation.md). Listening captures a
;;; client's microphone and feeds it to a speech worker, a separate
;;; program, since recognizing speech would block all of Tuna; each piece
;;; of text the worker finalizes goes to the listener's text callback on
;;; the editor thread. Text only ever grows: a piece is never revised. A
;;; piece keeps the model's spacing (most begin with a space), and may end
;;; or begin in the middle of a word.
;;;
;;; One listener at a time. Stopping ends the microphone at once; the
;;; pieces the worker still finalizes from the audio it already has
;;; arrive after voice-stop!, then the worker ends.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        (only-in :tuna/plugins/clients/contract client current-client))
(export (interface-out Voice)
        voice-service
        voice-start!
        voice-stop!
        voice-listening?)

(interface Voice
  (start! (c : client) (on-text : :procedure)) => :void
  (stop!) => :void
  (listening?) => :boolean)

(def voice-service
  (new-service 'voice is-Voice? tier: 'live
               doc: "Turns what a client's microphone hears into text."))

;; Listen to the microphone of client C, by default the one whose input
;; started the running command, and call ON-TEXT with each new piece of
;; text, on the editor thread. Raises when already listening, without a
;; client, or when the speech worker or its model is missing, saying
;; which.
(def (voice-start! (on-text : :procedure) client: (c :? client := (current-client))) => :void
  (unless c
    (error "Listening needs a browser tab"))
  (with-service-provider (provider voice-service Voice)
    (Voice-start! provider c on-text)))

;; Stop listening, if listening.
(def (voice-stop!) => :void
  (with-service-provider (provider voice-service Voice)
    (Voice-stop! provider)))

(def (voice-listening?) => :boolean
  (with-service-provider (provider voice-service Voice)
    (Voice-listening? provider)))
