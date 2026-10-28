;;; Pi chats (docs/briefs/2026-10-pi-chat.md): what other plugins see of
;;; the chats with the Pi coding agent that the pi plugin runs. A chat
;;; shows one Pi, held by a helper process outside Tuna, in a buffer: its
;;; transcript, a status bar and a prompt. Other plugins hand a chat text
;;; for its prompt or to send, and follow its state.
;;;
;;;   (pi-add-to-prompt! (car (pi-chats)) (format "```\n~a\n```\n" output))
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        (only-in :tuna/plugins/buffers/contract buffer))
(export pi-chat
        pi-chat?
        pi-chat-id
        pi-chat-buffer
        pi-chat-directory
        pi-chat-state
        (interface-out Pi)
        pi-service
        pi-chats
        pi-add-to-prompt!
        pi-send!
        pi-chat-state-hook)

;; One chat: ID names its helper; SHOWN, its buffer, shows it; DIRECTORY
;; is the folder Pi works in; STATE is what Pi is doing as other plugins
;; see it: 'idle (nothing yet), 'working, 'blocked (a question waits for
;; an answer), 'done (settled after working) or 'error (Pi stopped or
;; failed). The pi plugin extends this class and keeps its fields current.
(defclass pi-chat ((id        : :string)
                   (shown     : buffer)          ; `pi-chat-buffer`
                   (directory : :string)
                   (state     : :symbol)))

(def (pi-chat-buffer (c : pi-chat)) => buffer
  (pi-chat-shown c))

(interface Pi
  ;; The live chats, oldest first.
  (chats) => :list
  ;; Insert TEXT into CHAT's prompt at its end.
  (add-to-prompt! (chat : pi-chat) (text : :string)) => :void
  ;; Send TEXT to CHAT's Pi as the user's message; queued while Pi works.
  (send! (chat : pi-chat) (text : :string)) => :void)

(def pi-service
  (new-service 'pi is-Pi? tier: 'live
               doc: "Chats with the Pi coding agent, each in a buffer."))

(def (pi-chats) => :list
  (:- (with-service-provider (provider pi-service Pi) (Pi-chats provider)) :list))

(def (pi-add-to-prompt! (chat : pi-chat) (text : :string)) => :void
  (:- (with-service-provider (provider pi-service Pi) (Pi-add-to-prompt! provider chat text)) :void))

(def (pi-send! (chat : pi-chat) (text : :string)) => :void
  (:- (with-service-provider (provider pi-service Pi) (Pi-send! provider chat text)) :void))

(def pi-chat-state-hook
  (new-hook 'pi-chat-state
            doc: "Runs with a chat and its new state ('working, 'blocked, 'done or 'error) when the state changes."))
