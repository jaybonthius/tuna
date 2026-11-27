#!tuna
(import (chat) (fake-agents))

(define source
  (chat:source (conversation? values) (conversations list) (title "x") (mode 'm) (directory values) (session values)
               (start values) (items values) (item-key values) (draw-item values) (activity values) (working? values)
               (history fake-agents:echo-history) (drafts fake-agents:echo-drafts) (send values) (cancel values)
               (questions values)))
