;;; What the Pi helper replays to a Tuna connecting mid-reply: the open
;;; message with its updates, running tools with only their latest
;;; update, open compactions, the latest queue and status texts, and the
;;; dialogs still waiting; and when Pi counts as settled.
(import :std/test
        :tuna/plugins/pi/jsonl
        :tuna/plugins/pi/replay)
(export replay-test)

(def (note! (r : replay-state) (line : :string) (now : :real := 0)) => :void
  (replay-note-pi-line! r line (parse-json-line line) now))

(def (types (lines : :list)) => :list
  (map (lambda (line) (json-field (parse-json-line line) "type")) lines))

(def replay-test
  (test-suite "tuna/plugins/pi: replay"
    (test-case "the message being written replays with every update; a finished one does not"
      (let (r (new-replay-state))
        (note! r "{\"type\":\"agent_start\"}")
        (note! r "{\"type\":\"message_start\",\"message\":{\"role\":\"user\"}}")
        (note! r "{\"type\":\"message_end\",\"message\":{\"role\":\"user\"}}")
        (note! r "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\"}}")
        (note! r "{\"type\":\"message_update\",\"n\":1}")
        (note! r "{\"type\":\"message_update\",\"n\":2}")
        (check (replay-lines r 0)
               => ["{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\"}}"
                   "{\"type\":\"message_update\",\"n\":1}" "{\"type\":\"message_update\",\"n\":2}"])
        (check (replay-settled? r) => #f)
        (note! r "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\"}}")
        (check (replay-lines r 0) => [])))

    (test-case "a running tool replays its start and latest update, in the order items opened"
      (let (r (new-replay-state))
        (note! r "{\"type\":\"tool_execution_start\",\"toolCallId\":\"a\"}")
        (note! r "{\"type\":\"compaction_start\",\"reason\":\"threshold\"}")
        (note! r "{\"type\":\"tool_execution_update\",\"toolCallId\":\"a\",\"n\":1}")
        (note! r "{\"type\":\"tool_execution_update\",\"toolCallId\":\"a\",\"n\":2}")
        (check (replay-lines r 0)
               => ["{\"type\":\"tool_execution_start\",\"toolCallId\":\"a\"}"
                   "{\"type\":\"tool_execution_update\",\"toolCallId\":\"a\",\"n\":2}"
                   "{\"type\":\"compaction_start\",\"reason\":\"threshold\"}"])
        (note! r "{\"type\":\"tool_execution_end\",\"toolCallId\":\"a\"}")
        (note! r "{\"type\":\"compaction_end\"}")
        (check (replay-lines r 0) => [])
        (check (replay-settled? r) => #t)))

    (test-case "the latest queue and each key's status text stick; a cleared status goes"
      (let (r (new-replay-state))
        (note! r "{\"type\":\"queue_update\",\"steering\":[],\"followUp\":[\"a\"]}")
        (note! r "{\"type\":\"queue_update\",\"steering\":[],\"followUp\":[\"a\",\"b\"]}")
        (note! r "{\"type\":\"extension_ui_request\",\"id\":\"1\",\"method\":\"setStatus\",\"statusKey\":\"k\",\"statusText\":\"one\"}")
        (note! r "{\"type\":\"extension_ui_request\",\"id\":\"2\",\"method\":\"setStatus\",\"statusKey\":\"j\",\"statusText\":\"two\"}")
        (note! r "{\"type\":\"extension_ui_request\",\"id\":\"3\",\"method\":\"setStatus\",\"statusKey\":\"k\",\"statusText\":\"three\"}")
        (note! r "{\"type\":\"extension_ui_request\",\"id\":\"4\",\"method\":\"setStatus\",\"statusKey\":\"j\"}")
        (note! r "{\"type\":\"extension_ui_request\",\"id\":\"5\",\"method\":\"setWidget\",\"widgetKey\":\"w\"}")
        (check (replay-lines r 0)
               => ["{\"type\":\"queue_update\",\"steering\":[],\"followUp\":[\"a\",\"b\"]}"
                   "{\"type\":\"extension_ui_request\",\"id\":\"3\",\"method\":\"setStatus\",\"statusKey\":\"k\",\"statusText\":\"three\"}"])))

    (test-case "a dialog replays until answered or past its timeout, even after Pi settles"
      (let (r (new-replay-state))
        (note! r "{\"type\":\"agent_start\"}")
        (note! r "{\"type\":\"extension_ui_request\",\"id\":\"d1\",\"method\":\"select\",\"options\":[\"a\"]}" 10)
        (note! r "{\"type\":\"extension_ui_request\",\"id\":\"d2\",\"method\":\"confirm\",\"timeout\":5000}" 10)
        (note! r "{\"type\":\"agent_settled\",\"aborted\":false}")
        (check (types (replay-lines r 12)) => ["extension_ui_request" "extension_ui_request"])
        (check (replay-dialog-count r 12) => 2)
        (check (replay-dialog-count r 16) => 1)
        (replay-note-tuna-record! r (parse-json-line "{\"type\":\"extension_ui_response\",\"id\":\"d1\",\"value\":\"a\"}"))
        (check (replay-dialog-count r 16) => 0)))

    (test-case "agent_settled closes items whose end never came"
      (let (r (new-replay-state))
        (note! r "{\"type\":\"agent_start\"}")
        (note! r "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\"}}")
        (note! r "{\"type\":\"tool_execution_start\",\"toolCallId\":\"a\"}")
        (note! r "{\"type\":\"agent_settled\",\"aborted\":true}")
        (check (replay-lines r 0) => [])
        (check (replay-settled? r) => #t)))))
