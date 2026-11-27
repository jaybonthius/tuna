#!tuna
(import (chat) (chat-test fake-agents))

(define source
  (chat:source (conversation? values) (conversations list) (title "x") (mode 'm) (directory values) (session values)
               (start values) (items values) (item-key values) (draw-item values) (activity values) (working? values)
               (history chat-test/fake-agents:echo-history) (drafts chat-test/fake-agents:echo-drafts) (send values) (cancel values)
               (questions values)))
