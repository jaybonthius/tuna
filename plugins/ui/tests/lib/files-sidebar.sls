#!tuna
(import (ui) (buffers) (document) (commands) (files) (layout))

(define sidebar
  (or (buffers:find "*files*") (buffers:make "*files*" "\n")))

(commands:define-command (visit-entry [button (ui:pushed-button)])
  "Visits the file the entry names."
  (layout:switch-to-buffer (files:visit (document:node-attribute button 'path))))

(ui:define-button entry visit-entry)

(buffers:replace! sidebar 1 1 (entry '((path . "~/notes.org")) "notes.org"))
