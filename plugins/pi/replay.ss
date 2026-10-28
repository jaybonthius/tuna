;;; What the Pi helper remembers for a Tuna that connects while Pi works
;;; (agents/research/pi-chat/pi-rpc-and-helper.md §2). Pi's `get_messages`
;;; holds only completed messages, so a Tuna connecting mid-reply asks
;;; Pi, through the helper, for its state and messages, and then gets
;;; what those cannot say, as Pi wrote it:
;;;   1. the open items, in the order they opened: the message being
;;;      written (its `message_start` and every `message_update` since),
;;;      each running tool (its `tool_execution_start` and latest
;;;      `tool_execution_update`), an open compaction, retry or summary
;;;      retry;
;;;   2. sticky values: the latest `queue_update`, the latest `setStatus`
;;;      text of each key;
;;;   3. the dialogs Pi waits on an answer to, dropped once one is answered
;;;      or its timeout has passed.
;;; Because Pi writes its responses and events to one ordered stream,
;;; everything completed before the `get_messages` response is in it, and
;;; everything after it is sent live: nothing is lost or sent twice.
;;;
;;; Pi is settled once `agent_settled` follows its last `agent_start` and
;;; no item is open; `agent_settled` also closes items whose end never
;;; came. Plain data and lines in, lines out; no threads.
prelude: :gerbil/core

(import ./jsonl)
(export replay-state
        replay-state?
        new-replay-state
        replay-note-pi-line!
        replay-note-tuna-record!
        replay-lines
        replay-settled?
        replay-dialog-count)

;; One open item: KEY ('message, 'compaction, 'retry, 'summary, or the
;; tool call id) and its lines, newest first.
(defclass open-item ((key : :t) (lines : :list))
  final: #t)

;; ITEMS newest first; QUEUE the latest queue_update line or #f; STATUSES
;; (KEY . LINE), oldest first; DIALOGS (ID LINE DEADLINE), newest first,
;; DEADLINE the time in seconds past which Pi gave up, or #f.
(defclass replay-state ((items    : :list)
                        (queue    :? :string)
                        (statuses : :list)
                        (dialogs  : :list)
                        (busy?    : :boolean))
  final: #t)

(def (new-replay-state) => replay-state
  (replay-state items: [] queue: #f statuses: [] dialogs: [] busy?: #f))

(def dialog-methods '("select" "confirm" "input" "editor"))

(def (find-item (r : replay-state) (key : :t)) => (Maybe open-item)
  (find (lambda ((item : open-item)) (equal? item.key key)) r.items))

(def (open-item! (r : replay-state) (key : :t) (line : :string)) => :void
  (drop-item! r key)
  (set! r.items (cons (open-item key: key lines: [line]) r.items)))

(def (drop-item! (r : replay-state) (key : :t)) => :void
  (set! r.items (filter (lambda ((item : open-item)) (not (equal? item.key key))) r.items)))

;; LINE, which Pi wrote, parsed as RECORD, at time NOW (seconds).
(def (replay-note-pi-line! (r : replay-state) (line : :string) (record : :t) (now : :real)) => :void
  (let (type (json-field record "type"))
    (cond
     ((equal? type "message_start") (open-item! r 'message line))
     ((equal? type "message_update")
      (let (item (find-item r 'message))
        (when item (set! (open-item-lines item) (cons line (open-item-lines item))))))
     ((equal? type "message_end") (drop-item! r 'message))
     ((member type '("tool_execution_start" "tool_execution_update" "tool_execution_end"))
      (let (id (json-field record "toolCallId"))
        (when (string? id)
          (cond
           ((equal? type "tool_execution_start") (open-item! r id line))
           ((equal? type "tool_execution_end") (drop-item! r id))
           (else
            (let (item (find-item r id))
              (when item
                ;; An update holds all the output so far: the latest wins.
                (set! (open-item-lines item) [line (last (open-item-lines item))]))))))))
     ((equal? type "compaction_start") (open-item! r 'compaction line))
     ((equal? type "compaction_end") (drop-item! r 'compaction))
     ((equal? type "auto_retry_start") (open-item! r 'retry line))
     ((equal? type "auto_retry_end") (drop-item! r 'retry))
     ((member type '("summarization_retry_scheduled" "summarization_retry_attempt_start")) (open-item! r 'summary line))
     ((equal? type "summarization_retry_finished") (drop-item! r 'summary))
     ((equal? type "agent_start") (set! r.busy? #t))
     ((equal? type "agent_settled")
      (set! r.busy? #f)
      (set! r.items []))
     ((equal? type "queue_update") (set! r.queue line))
     ((equal? type "extension_ui_request") (note-ui-request! r line record now))
     (else (void)))))

(def (note-ui-request! (r : replay-state) (line : :string) (record : :t) (now : :real)) => :void
  (let ((method (json-field record "method"))
        (id (json-field record "id")))
    (cond
     ((and (member method dialog-methods) (string? id))
      (let (timeout (json-field record "timeout"))
        (set! r.dialogs (cons [id line (and (real? timeout) (> timeout 0) (+ now (/ timeout 1000.)))] r.dialogs))))
     ((equal? method "setStatus")
      (let ((key (json-field record "statusKey"))
            (text (json-field record "statusText")))
        (when (string? key)
          (set! r.statuses (append (filter (lambda ((entry : :pair)) (not (equal? (car entry) key))) r.statuses)
                                   (if (string? text) [(cons key line)] []))))))
     (else (void)))))

;; RECORD, which a Tuna sent Pi: an answer to a dialog drops the dialog.
(def (replay-note-tuna-record! (r : replay-state) (record : :t)) => :void
  (when (equal? (json-field record "type") "extension_ui_response")
    (let (id (json-field record "id"))
      (set! r.dialogs (filter (lambda ((dialog : :list)) (not (equal? (car dialog) id))) r.dialogs)))))

(def (prune-dialogs! (r : replay-state) (now : :real)) => :void
  (set! r.dialogs (filter (lambda ((dialog : :list)) (let (deadline (caddr dialog)) (or (not deadline) (< now deadline))))
                          r.dialogs)))

;; The lines a Tuna gets after Pi's state and messages, at time NOW: open
;; items, sticky values, then pending dialogs, each in the order Pi wrote
;; them.
(def (replay-lines (r : replay-state) (now : :real)) => :list
  (prune-dialogs! r now)
  (append (append-map (lambda ((item : open-item)) (reverse item.lines)) (reverse r.items))
          (if r.queue [r.queue] [])
          (map cdr r.statuses)
          (map cadr (reverse r.dialogs))))

;; Whether Pi has settled with nothing open.
(def (replay-settled? (r : replay-state)) => :boolean
  (and (not r.busy?) (null? r.items)))

;; How many dialogs wait on an answer at time NOW.
(def (replay-dialog-count (r : replay-state) (now : :real)) => :fixnum
  (prune-dialogs! r now)
  (length r.dialogs))

(def (append-map (f : :procedure) (l : :list)) => :list
  (apply append (map f l)))
