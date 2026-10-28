#lang :tuna/prelude
;;; Pi chats (live tier; docs/briefs/2026-10-pi-chat.md, after Pilish):
;;; `M-x pi` opens a chat with the Pi coding agent for the current
;;; buffer's project (its git root, else its folder), `M-x pi-new` another.
;;; Each chat runs `pi --mode rpc` in a helper process outside Tuna
;;; (helper.ss), so Pi goes on working while Tuna restarts; the plugin
;;; keeps its chats in its session slot and reconnects, the helper
;;; replaying what Pi is in the middle of. A chat whose helper is gone
;;; (a reboot, or Pi idle with no Tuna for `idle-exit` seconds) starts a
;;; new one on Pi's session file. Pi stopping shows its standard error once,
;;; with a Restart button.
;;;
;;; A chat is a buffer: the transcript (transcript.ss), read-only but for
;;; moving, selecting and copying; a status bar (model · thinking level ·
;;; what Pi does · context used · cost · queued messages · extensions'
;;; status texts); and the prompt, an editable text styled as Markdown as
;;; it is typed. Pi's records arrive through a job reading the helper's
;;; socket, in batches; the chat's state changes first, then what is
;;; drawn: streamed text, thinking and tool output at most every 50 ms,
;;; everything else at once, after drawing what streamed before it. A
;;; view at the chat's bottom stays there as it grows.
;;;
;;; In the prompt: RET sends (queued by Pi while it works), S-RET a new
;;; line, M-RET steers, C-c C-k stops Pi, M-p and M-n earlier prompts. In
;;; the transcript: TAB folds a tool or thinking block, RET opens the file
;;; at point (a tool's file, or FILE:LINE in its output), n and p move
;;; between your messages. An extension's question waits in the chat,
;;; answered with RET or its Answer button (C-g cancels).
;;;
;;; Each chat's state ('working, 'blocked, 'done, 'error) runs the
;;; contract's pi-chat-state-hook and goes to the program-status service.

(import (only-in :gerbil/runtime/hash HashTable)
        :std/interface
        :std/encoding/json
        :tuna/kernel
        :tuna/lib/jobs
        :tuna/lib/timers
        :tuna/lib/plugin-options
        (only-in :tuna/lib/helper-processes helper-socket-directory helper-socket-path helper-leaves-scope?
                 wait-for-socket)
        :tuna/plugins/commands/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/settings/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/session/contract
        :tuna/plugins/clients/contract
        :tuna/plugins/stylesheets/contract
        :tuna/plugins/markdown/contract
        (only-in :tuna/plugins/minibuffer/contract minibuffer-service read-from-minibuffer read-string
                 prompt-keymap)
        (only-in :tuna/plugins/completion/contract completion-service completion-ui-service completing-read make-completion-table
                 strings->candidates)
        (only-in :tuna/plugins/buttons/contract new-button)
        (only-in :tuna/plugins/layout/contract layout-service view-list posn-node)
        (only-in :tuna/plugins/files/contract files-service file-system-service default-directory
                 buffer-default-directory find-file-at-line find-file-references)
        (only-in :tuna/plugins/program-status/contract program-status-service report-program-status!
                 make-program-status-report)
        :tuna/plugins/pi/contract
        ./jsonl
        ./connection
        ./tool-text
        ./transcript)
(export pi)

;;; State

;; One connection to a helper, from starting or finding it to its end:
;; HELPER-ID names its socket and log; requests sent on it have ids
;; starting with PREFIX; OUTBOX holds what waits for CONNECTED, the
;; connection, newest first; LIVE? once Pi's state and messages arrived.
(defclass helper-link ((helper-id : :string)
                       (socket    : :string)
                       (inbox     : record-inbox)
                       (reader    :? job)              ; the job reading it
                       (connected :? connection)
                       (outbox    : :list)
                       (prefix    : :string)
                       (live?     : :boolean)
                       (refused?  : :boolean)
                       (exited?   : :boolean))
  final: #t)

;; One open extension dialog: Pi's request, its node, and its timer.
(defclass question ((id      : :string)
                    (request : :t)
                    (element : node)
                    (timer   :? :t))
  final: #t)

(defclass (live-chat pi-chat)
  ((link        :? helper-link)
   (candidate   :? helper-link)              ; a reload's new helper, until its snapshot
   (root        : node)
   (status-node : node)
   (prompt      : text)
   (prompt-node : node)               ; the prompt's text node
   (messages    : :list)              ; chat-messages, newest first
   (questions   : :list)              ; newest first
   (tools       : HashTable)          ; toolCallId -> chat-tool
   (current     :? chat-message)      ; Pi's message being written
   (pending     : HashTable)          ; request id -> procedure of the response record
   (requests    : :fixnum)
   (session-file :? :string)
   (model       :? :string)
   (thinking    :? :string)
   (busy?       : :boolean)
   (compacting? : :boolean)
   (retrying?   : :boolean)
   (queued      : :fixnum)
   (context-percent :? :real)
   (cost        :? :real)
   (statuses    : :list)              ; (key . text), oldest first
   (dirty       : :list)              ; parts and tools whose streamed text waits to be drawn
   (updates     : HashTable)          ; toolCallId -> latest partial result not yet drawn
   (flush-timer :? :t)
   (history     : :list)              ; prompts sent, newest first
   (history-index :? :fixnum)
   (draft       : :string)            ; the prompt before M-p
   (follow      : HashTable)          ; view -> number of the placement putting it at the bottom
   (stopped     :? :string)           ; why Pi stopped, once shown
   (refusals    : :fixnum)
   (failure     :? :string))
  final: #t)

(defclass pi-state ((ctx      : context)
                    (chats    : HashTable)       ; id -> live-chat
                    (by-buffer : HashTable)      ; buffer -> live-chat
                    (order    : :list)           ; chats, newest first
                    (jobs     : job-group)
                    (keymaps  : transcript-keymaps)
                    (prompt-map : entry-table)
                    (question-map : entry-table)
                    (clients  : :list)           ; clients that used a chat
                    (waiting  : :list)           ; chats to connect once the loop runs
                    (stopping? : :boolean))
  final: #t)

(def (now) => :real (time->seconds (current-time)))

(def (service-there? (s : service)) => :boolean
  (and (service-provider s) #t))

;; A fresh id, unique across Tuna's runs.
(def (random-id (bytes : :fixnum)) => :string
  (let (b (with-catch (lambda (e) (let (b (make-u8vector bytes 0))
                                    (let lp ((i 0)) (when (fx< i bytes) (u8vector-set! b i (random-integer 256)) (lp (fx1+ i))))
                                    b))
                      (lambda () (call-with-input-file "/dev/urandom"
                                   (lambda (port) (let (b (make-u8vector bytes 0)) (read-subu8vector b 0 bytes port) b))))))
    (:- (apply string-append (map (lambda (n) (string-append (if (< n 16) "0" "") (number->string n 16)))
                                  (u8vector->list b)))
        :string)))

(def (socket-directory) => :string
  (helper-socket-directory "pi" (:- (plugin-option pi 'socket-directory) :string)))

(def (unique-buffer-name (name : :string)) => :string
  (if (not (get-buffer name))
    name
    (let lp ((n 2))
      (let (candidate (string-append name "<" (number->string n) ">"))
        (if (get-buffer candidate) (lp (fx1+ n)) candidate)))))

(def (without-final-slash (directory : :string)) => :string
  (if (and (fx> (string-length directory) 1) (string-suffix? "/" directory))
    (substring directory 0 (fx1- (string-length directory)))
    directory))

;; The project of DIRECTORY: the nearest folder at or above it holding
;; .git, else DIRECTORY itself.
(def (project-directory (directory : :string)) => :string
  (let (start (without-final-slash (path-normalize* directory)))
    (let up ((folder start))
      (cond
       ((file-exists? (path-expand ".git" folder)) folder)
       ((or (equal? folder "/") (string-empty? folder)) start)
       (else (up (without-final-slash (path-directory folder))))))))

(def (path-normalize* (path : :string)) => :string
  (with-catch (lambda (e) path) (lambda () (path-normalize path))))

;;; Chats and their buffers

(def (chat-name (directory : :string)) => :string
  (string-append "*pi: " (path-strip-directory directory) "*"))

(def (new-live-chat (self : pi-state) (id : :string) (name : :string) (directory : :string)) => live-chat
  (let* ((prompt (new-text ""))
         (prompt-node (new-text-node prompt))
         (status (new-node 'pi-status attributes: [(cons 'parts [])]))
         (root (new-node 'pi-chat children: [status (new-node 'pi-prompt children: [prompt-node])]))
         (b (new-buffer name root))
         (chat (live-chat id: id shown: b directory: directory state: 'idle
                          link: #f candidate: #f root: root status-node: status prompt: prompt prompt-node: prompt-node
                          messages: [] questions: [] tools: (make-hash-table) current: #f
                          pending: (make-hash-table) requests: 0 session-file: #f model: #f thinking: #f
                          busy?: #f compacting?: #f retrying?: #f queued: 0 context-percent: #f cost: #f
                          statuses: [] dirty: [] updates: (make-hash-table) flush-timer: #f history: []
                          history-index: #f draft: "" follow: (make-hash-table-eq) stopped: #f refusals: 0
                          failure: #f)))
    (set-node-keymap! prompt-node self.prompt-map)
    (markdown-style-text! prompt)
    (add-buffer! b)
    (set-buffer-setting! b default-directory (string-append directory "/"))
    (hash-put! self.chats id chat)
    (hash-put! self.by-buffer b chat)
    (set! self.order (cons chat self.order))
    (draw-status! chat)
    chat))

(def (current-chat (self : pi-state)) => (Maybe live-chat)
  (hash-get self.by-buffer (current-buffer)))

(def (this-chat (self : pi-state)) => live-chat
  (or (current-chat self) (error "Not in a Pi chat")))

(def (views-showing (chat : live-chat)) => :list
  (if (service-there? layout-service)
    (filter (lambda ((v : view)) (eq? (view-showing v) (pi-chat-buffer chat))) (view-list))
    (let (v (selected-view))
      (if (eq? (view-showing v) (pi-chat-buffer chat)) [v] []))))

;; The root's children: the messages, oldest first, the open questions,
;; the status bar, the prompt.
(def (refresh-root! (chat : live-chat)) => :void
  (set-node-children! chat.root
                      (append (map chat-message-element (reverse chat.messages))
                              (map question-element (reverse chat.questions))
                              [chat.status-node (node-parent chat.prompt-node)])))

(def (add-message! (chat : live-chat) (m : chat-message)) => :void
  (set! chat.messages (cons m chat.messages))
  (refresh-root! chat))

;; Show TEXT, a notice of LEVEL ('info or 'error), at the end of the
;; transcript, with EXTRA nodes after it.
(def (notice! (self : pi-state) (chat : live-chat) (text : :string) (level : :symbol) (extra : :list := [])) => :void
  (add-message! chat (new-notice text level self.keymaps extra)))

;;; Following the bottom

;; The last item of the chat: the prompt's last line.
(def (bottom-item (chat : live-chat)) => item
  (node-line-item chat.prompt-node (fx1+ (text-size chat.prompt))))

;; Whether V, showing CHAT, is at its bottom: still where the chat put it
;; to follow, or a browser measured the status bar or the prompt in view.
(def (following? (self : pi-state) (chat : live-chat) (v : view)) => :boolean
  (or (eqv? (hash-get chat.follow v) (placement-number (view-placement v)))
      (ormap (lambda ((c : client))
               (let* ((cv (view-client v c))
                      (facts (client-view-facts cv)))
                 (and facts
                      (fx= (scroll-facts-placement facts) (placement-number (client-view-placement cv)))
                      (let (seen (scroll-facts-last-visible facts))
                        (and seen (memq (item-node seen) [chat.prompt-node chat.status-node]) #t)))))
             self.clients)))

(def (place-at-bottom! (chat : live-chat) (v : view)) => :void
  (place-view! v (bottom-item chat) 'bottom)
  (hash-put! chat.follow v (placement-number (view-placement v))))

;; Run THUNK, which may make CHAT longer, keeping views that were at its
;; bottom there.
(def (keeping-bottom! (self : pi-state) (chat : live-chat) (thunk : :procedure)) => :void
  (let (following (filter (cut following? self chat <>) (views-showing chat)))
    (thunk)
    (for-each (cut place-at-bottom! chat <>) following)))

;;; The status bar

(def (running-tool (chat : live-chat)) => (Maybe chat-tool)
  (find (lambda ((t : chat-tool)) (eq? (chat-tool-state t) 'running)) (hash-values chat.tools)))

(def (replying? (chat : live-chat)) => :boolean
  (let (m chat.current)
    (and m
         (let* ((parts (chat-message-parts m))
                (indices (hash-keys parts)))
           (and (pair? indices)
                (let (last (hash-ref parts (apply max indices)))
                  (and (eq? (message-part-kind last) 'text) (not (message-part-done? last)))))))))

(def (live? (chat : live-chat)) => :boolean
  (let (l chat.link) (and l (helper-link-live? l) #t)))

(def (chat-phase (chat : live-chat)) => :string
  (cond
   (chat.stopped "stopped")
   ((pair? chat.questions) "blocked")
   (chat.compacting? "compacting")
   (chat.retrying? "retrying")
   ((running-tool chat) => (lambda (t) (string-append "running " (chat-tool-name t))))
   (chat.busy? (if (replying? chat) "replying" "thinking"))
   ((not (live? chat)) "connecting")
   (else "idle")))

(def (percent-text (p : :real)) => :string
  (string-append (number->string (exact (round p))) "%"))

(def (cost-text (cost : :real)) => :string
  (let (cents (exact (round (* cost 100))))
    (string-append "$" (number->string (quotient cents 100)) "."
                   (if (< (remainder cents 100) 10) "0" "") (number->string (remainder cents 100)))))

(def (draw-status! (chat : live-chat)) => :void
  (set-node-attribute! chat.status-node 'parts
                       (append (filter values
                                       [chat.model chat.thinking (chat-phase chat)
                                        (and chat.context-percent (percent-text chat.context-percent))
                                        (and chat.cost (cost-text chat.cost))
                                        (and (fx> chat.queued 0) (string-append (number->string chat.queued) " queued"))])
                               (map cdr chat.statuses))))

;; CHAT's state as other plugins see it, from what it does now, told to
;; them when it changes.
(def (update-state! (chat : live-chat)) => :void
  (let* ((old (pi-chat-state chat))
         (new (cond
               (chat.stopped 'error)
               ((pair? chat.questions) 'blocked)
               ((or chat.busy? chat.compacting?) 'working)
               ((memq old '(working blocked)) 'done)
               (else old))))
    (unless (eq? new old)
      (set! chat.state new)
      (run-hook-safely pi-chat-state-hook chat new)
      (when (and (service-there? program-status-service) (memq new '(working blocked done error)))
        (with-catch
         void
         (lambda ()
           (report-program-status! (pi-chat-buffer chat)
                                   (make-program-status-report
                                    "" new (and (eq? new 'blocked) 'question) #f "pi" #f
                                    (case new
                                      ((working) "Pi is working")
                                      ((blocked) "Pi asks a question")
                                      ((done) "Pi is done")
                                      (else (or chat.stopped "Pi stopped")))))))))))

(def (run-hook-safely (hook : :t) . args) => :void
  (with-catch (lambda (e) (when (quit-condition? e) (raise e))) (lambda () (apply run-hook hook args))))

;;; Requests

;; Send RECORD to CHAT's Pi with a new id; ON-RESPONSE, when given, gets
;; Pi's response, or a failed one of Tuna's own if Pi stops first.
(def (request! (chat : live-chat) (record : HashTable) (on-response :? :procedure := #f)) => :void
  (let (l chat.link)
    (if (not l)
      (when on-response (on-response (failed-response "Pi is not running")))
      (begin
        (set! chat.requests (fx1+ chat.requests))
        (let (id (string-append (helper-link-prefix l) (number->string chat.requests)))
          (hash-put! record "id" id)
          (when on-response (hash-put! chat.pending id on-response))
          (send-line! l record))))))

(def (send-line! (l : helper-link) (record : HashTable)) => :void
  (let (c l.connected)
    (if c
      (connection-send! c record)
      (set! l.outbox (cons record l.outbox)))))

(def (failed-response (why : :string)) => HashTable
  (hash ("type" "response") ("success" #f) ("error" why)))

;; Every request waiting for a response gets a failed one.
(def (fail-pending! (chat : live-chat) (why : :string)) => :void
  (let (waiting (hash-values chat.pending))
    (hash-clear! chat.pending)
    (for-each (lambda ((on-response : :procedure))
                (with-catch (lambda (e) (when (quit-condition? e) (raise e)))
                            (lambda () (on-response (failed-response why)))))
              waiting)))

(def (response-data (record : :t)) => :t
  (json-field record "data"))

(def (response-ok? (record : :t)) => :boolean
  (eq? (json-field record "success") #t))

(def (response-error (record : :t)) => :string
  (let (e (json-field record "error"))
    (if (string? e) e "Pi refused")))

;;; Starting helpers and reading them

(def (trust-name) => :string
  (symbol->string (:- (plugin-option pi 'trust) :symbol)))

;; The launch of a new helper with id ID for CHAT, opening SESSION (#f: a
;; new session).
(def (chat-launch (chat : live-chat) (id : :string) (socket : :string) (session :? :string)) => helper-launch
  (let ((model (plugin-option pi 'model))
        (thinking (plugin-option pi 'thinking)))
    (make-helper-launch (:- (plugin-option pi 'helper) :string) socket (pi-chat-directory chat)
                        (path-expand (string-append id ".log") (path-directory socket))
                        (:- (plugin-option pi 'idle-exit) :fixnum)
                        (and (string? model) model) (and (symbol? thinking) (symbol->string thinking))
                        (trust-name) session
                        (:- (plugin-option pi 'pi-command) :list)
                        (and (helper-leaves-scope? (:- (plugin-option pi 'leave-scope) :symbol))
                             (string-append "tuna-pi-" id)))))

;; CHAT's session file, if Pi has written it.
(def (existing-session (chat : live-chat)) => (Maybe :string)
  (let (file chat.session-file)
    (and file (file-exists? file) file)))

(def (new-link (helper-id : :string) (socket : :string)) => helper-link
  (helper-link helper-id: helper-id socket: socket inbox: (new-record-inbox (* 16 1024 1024)) reader: #f connected: #f
        outbox: [] prefix: (string-append (random-id 3) "-") live?: #f refused?: #f exited?: #f))

;; Start the job reading L, CHAT's link: it starts the helper with LAUNCH
;; first when one is given, waits for its socket, connects, and posts the
;; connection, then every batch of records, and ends with 'ended; 'gone
;; when no helper listens at the socket.
(def (start-reader! (self : pi-state) (chat : live-chat) (l : helper-link) (launch :? helper-launch)) => :void
  (if (editor-loop-running?)
    (set! l.reader
      (job-group-start! self.jobs l.helper-id
                        input: [launch l.socket l.inbox]
                        run: reader-run
                        apply: (lambda (result) (receive! self chat l result))))
    (set! self.waiting (cons (cons chat l) self.waiting))))

(def (reader-run (input : :list) (cancelled? : :procedure) (post! : :procedure)) => :t
  (let ((launch (car input))
        (socket (cadr input))
        (inbox (caddr input)))
    (with-catch
     (lambda (e) (if (eq? e 'gone) 'gone (cons 'failed (error-message e))))
     (lambda ()
       (when launch (launch-helper! launch))
       (if (not (wait-for-socket socket (if launch 20 0.5)))
         (if launch (cons 'failed "the Pi helper did not start") 'gone)
         (let ((c (or (with-catch
                       (lambda (e)
                         ;; No helper listens there: its socket is stale.
                         (if launch (raise e) (begin (with-catch void (lambda () (delete-file socket))) #f)))
                       (lambda () (open-connection socket)))
                      (raise 'gone)))
               (reader (new-jsonl-reader))
               (buffer (make-u8vector 65536 0)))
           (post! (cons 'connected c))
           (let lp ()
             (let (read (read-records (connection-device c) reader buffer))
               (when read
                 (when (record-inbox-put! inbox (car read) (cdr read)) (post! 'records))
                 (unless (cancelled?) (lp)))))
           'ended))))))

(def (error-message (e : :t)) => :string
  (let (text (and (error-object? e) (error-object-message e)))
    (if (string? text) text "error")))

;; What L's reader posted, on the editor: ignored once L is no longer
;; CHAT's link or candidate.
(def (receive! (self : pi-state) (chat : live-chat) (l : helper-link) (result : :t)) => :void
  (when (and (or (eq? l chat.link) (eq? l chat.candidate))
             (eq? (hash-get self.chats (pi-chat-id chat)) chat)
             (not self.stopping?))
    (cond
     ((and (pair? result) (eq? (car result) 'connected))
      (let (c (cdr result))
        (set! l.connected c)
        (for-each (cut connection-send! c <>) (reverse l.outbox))
        (set! l.outbox [])))
     ((eq? result 'records)
      (let (records (record-inbox-take! l.inbox))
        (keeping-bottom! self chat
                         (lambda ()
                           (for-each (lambda (record)
                                       (guarded! chat "a record from Pi"
                                                 (lambda () (record! self chat l record))))
                                     records)
                           (draw-status! chat)
                           (update-state! chat)))))
     ((and (pair? result) (eq? (car result) 'failed))
      (link-ended! self chat l)
      (pi-stopped! self chat (string-append "The Pi helper failed: " (cdr result)) ""))
     ((eq? result 'gone)
      (link-ended! self chat l)
      (when (eq? l chat.link)
        ;; No helper: start one on Pi's session file (a reboot, or an
        ;; idle exit).
        (start-helper! self chat (existing-session chat))))
     ((eq? result 'ended)
      (link-ended! self chat l)
      (cond
       ((not (eq? l chat.link)) (void))
       (chat.stopped (void))
       ;; Another Tuna holds it: try again.
       (l.refused?
        (set! chat.refusals (fx1+ chat.refusals))
        (if (fx< chat.refusals 50)
          (context-run-with-timer! self.ctx 0.2 #f (lambda () (reconnect! self chat)) name: 'pi-reconnect)
          (pi-stopped! self chat "Another Tuna is connected to this chat's Pi" "")))
       ;; Its helper went away: connect again, which starts a new one on
       ;; the session file when it is gone.
       (else
        (context-run-with-timer! self.ctx 1.0 #f (lambda () (reconnect! self chat)) name: 'pi-reconnect)))))))

;; L ended: what waited for its responses fails.
(def (link-ended! (self : pi-state) (chat : live-chat) (l : helper-link)) => :void
  (set! l.connected #f)
  (record-inbox-close! l.inbox)
  (cond
   ((eq? l chat.candidate)
    (set! chat.candidate #f)
    (message "Reloading Pi failed; the chat goes on with the Pi it had"))
   ((eq? l chat.link)
    (set! l.live? #f)
    (fail-pending! chat "Pi's helper went away")
    (draw-status! chat))))

(def (reconnect! (self : pi-state) (chat : live-chat)) => :void
  (let (l chat.link)
    (when (and l (not (helper-link-connected l)) (not chat.stopped) (eq? (hash-get self.chats (pi-chat-id chat)) chat))
      (let (fresh (new-link (helper-link-helper-id l) (helper-link-socket l)))
        (set! chat.link fresh)
        (start-reader! self chat fresh #f)))))

;; Start a new helper for CHAT on SESSION (#f: a new session) and connect
;; to it.
(def (start-helper! (self : pi-state) (chat : live-chat) (session :? :string)) => :void
  (let* ((id (random-id 8))
         (socket (helper-socket-path (socket-directory) id))
         (l (new-link id socket)))
    (set! chat.link l)
    (set! chat.stopped #f)
    (set! chat.refusals 0)
    (start-reader! self chat l (chat-launch chat id socket session))
    (draw-status! chat)))

;; Run THUNK, WHAT for CHAT, reporting a failure once while it repeats,
;; in the echo area and Tuna's log, and going on.
(def (guarded! (chat : live-chat) (what : :string) (thunk : :procedure)) => :void
  (with-catch
   (lambda (e)
     (if (quit-condition? e)
       (raise e)
       (let (report (string-append (buffer-name (pi-chat-buffer chat)) ": " what " failed: " (exception-summary e)))
         (unless (equal? report chat.failure)
           (set! chat.failure report)
           (let (port (current-error-port)) (display report port) (newline port))
           (message report)))))
   thunk))

;;; Records

(def streamed-events '("text_delta" "thinking_delta"))

(def (streamed? (record : :t)) => :boolean
  (let (type (json-field record "type"))
    (or (equal? type "tool_execution_update")
        (and (equal? type "message_update")
             (member (json-field (json-field record "assistantMessageEvent") "type") streamed-events)
             #t))))

(def (record! (self : pi-state) (chat : live-chat) (l : helper-link) (record : :t)) => :void
  (let ((type (json-field record "type"))
        (id (json-field record "id")))
    (cond
     ((equal? type "helper_hello")
      (let (problem (json-field record "error"))
        (when (and (string? problem) (eq? l chat.candidate))
          (message (string-append "Reloading Pi failed: " problem)))))
     ((equal? type "helper_refused") (set! l.refused? #t))
     ((equal? type "helper_exit")
      (set! l.exited? #t)
      (if (eq? l chat.candidate)
        (let (c l.connected) (when c (close-connection! c)))
        (pi-stopped! self chat (string-append "Pi stopped (exit status " (number->string (or (json-field record "status") 0)) ").")
                     (or (json-field record "stderr") ""))))
     ((and (equal? type "response") (equal? id "helper:state"))
      (adopt-state! chat (response-data record)))
     ((and (equal? type "response") (equal? id "helper:messages"))
      (snapshot! self chat l record))
     ((not (eq? l chat.link)) (void))
     ((equal? type "response")
      (let (on-response (and (string? id) (hash-get chat.pending id)))
        (when on-response
          (hash-remove! chat.pending id)
          (on-response record))))
     (else
      (unless (streamed? record) (flush! self chat))
      (event! self chat record)))))

;; Pi's state (get_state's data).
(def (adopt-state! (chat : live-chat) (state : :t)) => :void
  (when (hash-table? state)
    (let ((model (json-field state "model"))
          (file (json-field state "sessionFile")))
      (set! chat.model (and model (or (json-field model "name") (json-field model "id"))))
      (set! chat.thinking (let (t (json-field state "thinkingLevel")) (and (string? t) t)))
      (set! chat.busy? (eq? (json-field state "isStreaming") #t))
      (set! chat.compacting? (eq? (json-field state "isCompacting") #t))
      (when (string? file) (set! chat.session-file file)))))

;; Pi's messages (get_messages' response) on link L: the transcript drawn
;; from them; L is live, and a reload's new helper replaces the old.
(def (snapshot! (self : pi-state) (chat : live-chat) (l : helper-link) (record : :t)) => :void
  (when (eq? l chat.candidate)
    (let (old chat.link)
      (when old
        (let (c (helper-link-connected old))
          (when c
            (connection-send! c (hash ("type" "helper_kill")))
            (close-connection! c)))
        (record-inbox-close! (helper-link-inbox old))
        (let (j (helper-link-reader old)) (when j (job-cancel! j))))
      (fail-pending! chat "Pi was reloaded")
      (set! chat.link l)
      (set! chat.candidate #f)
      (message "Pi reloaded")))
  (when (eq? l chat.link)
    (set! l.live? #t)
    (set! chat.refusals 0)
    (rebuild-transcript! self chat (json-field (response-data record) "messages"))
    (request-stats! chat)
    (for-each (cut place-at-bottom! chat <>) (views-showing chat))))

(def (rebuild-transcript! (self : pi-state) (chat : live-chat) (messages : :t)) => :void
  (for-each (lambda ((q : question)) (let (t (question-timer q)) (when t (cancel-timer t)))) chat.questions)
  (set! chat.questions [])
  (set! chat.tools (make-hash-table))
  (hash-clear! chat.updates)
  (set! chat.dirty [])
  (set! chat.current #f)
  (set! chat.statuses [])
  (set! chat.queued 0)
  (set! chat.retrying? #f)
  (set! chat.messages
    (reverse (filter-map (lambda (m) (history-message m self.keymaps (cut tool-for self chat <> <> <>)
                                                      (cut hash-get chat.tools <>)))
                         (if (list? messages) messages []))))
  (refresh-root! chat))

(def (request-stats! (chat : live-chat)) => :void
  (request! chat (hash ("type" "get_session_stats"))
            (lambda (response)
              (when (response-ok? response)
                (let* ((data (response-data response))
                       (usage (json-field data "contextUsage"))
                       (percent (json-field usage "percent"))
                       (cost (json-field data "cost")))
                  (set! chat.context-percent (and (real? percent) percent))
                  (set! chat.cost (and (real? cost) cost))
                  (draw-status! chat))))))

;; The tool of id ID, NAME and ARGS, made when CHAT has none.
(def (tool-for (self : pi-state) (chat : live-chat) (id : :string) (name : :string) (args : :t)) => chat-tool
  (let (tool (hash-get chat.tools id))
    (if tool
      (begin (set-tool-args! tool args) tool)
      (let (tool (new-tool id name (if (hash-table? args) args (make-hash-table)) self.keymaps))
        (hash-put! chat.tools id tool)
        tool))))

;;; Events

(def (event! (self : pi-state) (chat : live-chat) (record : :t)) => :void
  (let (type (json-field record "type"))
    (cond
     ((equal? type "message_start") (message-started! self chat (json-field record "message")))
     ((equal? type "message_update") (message-updated! self chat (json-field record "assistantMessageEvent")))
     ((equal? type "message_end") (message-ended! self chat (json-field record "message")))
     ((equal? type "tool_execution_start")
      (let ((tool (tool-for self chat (or (json-field record "toolCallId") "") (or (json-field record "toolName") "tool")
                            (json-field record "args"))))
        (show-tool! self chat tool)
        (start-tool! tool (json-field record "args") (now))))
     ((equal? type "tool_execution_update")
      (let* ((id (or (json-field record "toolCallId") ""))
             (tool (hash-get chat.tools id)))
        (when tool
          (hash-put! chat.updates id (json-field record "partialResult"))
          (dirty! self chat tool))))
     ((equal? type "tool_execution_end")
      (let* ((id (or (json-field record "toolCallId") ""))
             (tool (hash-get chat.tools id)))
        (hash-remove! chat.updates id)
        (when tool
          (finish-tool! tool (json-field record "result") (eq? (json-field record "isError") #t)
                        (let (ms (json-field record "durationMs")) (and (real? ms) ms))))))
     ((equal? type "agent_start") (set! chat.busy? #t))
     ((equal? type "agent_settled") (settled! self chat))
     ((equal? type "compaction_start") (set! chat.compacting? #t))
     ((equal? type "compaction_end")
      (set! chat.compacting? #f)
      (let (problem (json-field record "errorMessage"))
        (when (string? problem) (notice! self chat (string-append "Compaction failed: " problem) 'error)))
      ;; The messages changed shape: draw them again.
      (when (json-field record "result")
        (request! chat (hash ("type" "get_messages"))
                  (lambda (response)
                    (when (response-ok? response)
                      (keeping-bottom! self chat
                                       (lambda ()
                                         (rebuild-transcript! self chat (json-field (response-data response) "messages"))))
                      (request-stats! chat))))))
     ((equal? type "auto_retry_start") (set! chat.retrying? #t))
     ((equal? type "auto_retry_end")
      (set! chat.retrying? #f)
      (unless (eq? (json-field record "success") #t)
        (let (problem (json-field record "finalError"))
          (notice! self chat (string-append "Pi gave up retrying" (if (string? problem) (string-append ": " problem) ".")) 'error))))
     ((equal? type "queue_update")
      (set! chat.queued (fx+ (let (s (json-field record "steering")) (if (list? s) (length s) 0))
                             (let (f (json-field record "followUp")) (if (list? f) (length f) 0)))))
     ((equal? type "thinking_level_changed")
      (let (level (json-field record "level")) (when (string? level) (set! chat.thinking level))))
     ((equal? type "extension_ui_request") (ui-request! self chat record))
     ((equal? type "extension_error")
      (message (string-append "A Pi extension failed: " (let (e (json-field record "error")) (if (string? e) e "")))))
     (else (void)))))

(def (message-started! (self : pi-state) (chat : live-chat) (m : :t)) => :void
  (let (role (json-field m "role"))
    (cond
     ((equal? role "user")
      (add-message! chat (new-role-message 'user (content-text (json-field m "content")) self.keymaps)))
     ((equal? role "assistant")
      (let (message (new-assistant-message self.keymaps))
        (set! chat.current message)
        (add-message! chat message)
        (let (content (json-field m "content"))
          (when (pair? content)
            (replace-assistant-content! message content self.keymaps (cut tool-for self chat <> <> <>))))))
     (else (void)))))

;; The part at content INDEX of Pi's message being written, made as KIND
;; when there is none (and TOOL for a tool part).
(def (current-part! (self : pi-state) (chat : live-chat) (index : :fixnum) (kind : :symbol)
                    (tool :? chat-tool := #f))
  => (Maybe message-part)
  (let (m chat.current)
    (and m
         (or (message-part-at m index)
             (add-message-part! m index kind self.keymaps tool: tool)))))

(def (message-updated! (self : pi-state) (chat : live-chat) (event : :t)) => :void
  (let* ((type (json-field event "type"))
         (index (let (i (json-field event "contentIndex")) (if (fixnum? i) i 0))))
    (cond
     ((member type '("text_start" "thinking_start"))
      (current-part! self chat index (if (equal? type "text_start") 'text 'thinking)))
     ((member type '("text_delta" "thinking_delta"))
      (let ((part (current-part! self chat index (if (equal? type "text_delta") 'text 'thinking)))
            (delta (json-field event "delta")))
        (when (and part (string? delta))
          (append-part-text! part delta)
          (dirty! self chat part))))
     ((member type '("text_end" "thinking_end"))
      (let ((part (current-part! self chat index (if (equal? type "text_end") 'text 'thinking)))
            (content (json-field event "content")))
        (when part
          (when (string? content) (set-part-text! part content))
          (finish-part! part self.keymaps))))
     ((equal? type "toolcall_start")
      (let (tool (tool-for self chat (or (json-field event "id") "") (or (json-field event "toolName") "tool") #f))
        (current-part! self chat index 'tool tool)))
     ((equal? type "toolcall_end")
      (let* ((call (json-field event "toolCall"))
             (tool (tool-for self chat (or (json-field call "id") "") (or (json-field call "name") "tool")
                             (json-field call "arguments"))))
        (current-part! self chat index 'tool tool)))
     (else (void)))))

(def (message-ended! (self : pi-state) (chat : live-chat) (m : :t)) => :void
  (let (role (json-field m "role"))
    (cond
     ((equal? role "assistant")
      (let (message (or chat.current
                        (let (message (new-assistant-message self.keymaps))
                          (add-message! chat message)
                          message)))
        (replace-assistant-content! message (json-field m "content") self.keymaps (cut tool-for self chat <> <> <>))
        (set-message-error! message (assistant-error m))
        (set! chat.current #f)))
     ((equal? role "user") (void))
     (else
      (let (message (history-message m self.keymaps (cut tool-for self chat <> <> <>) (cut hash-get chat.tools <>)))
        (when message (add-message! chat message)))))))

;; Show TOOL, which Pi runs, in the message being written when no message
;; shows it yet.
(def (show-tool! (self : pi-state) (chat : live-chat) (tool : chat-tool)) => :void
  (unless (node-parent (chat-tool-element tool))
    (let (m chat.current)
      (if m
        (let (indices (hash-keys (chat-message-parts m)))
          (add-message-part! m (if (null? indices) 0 (fx1+ (apply max indices))) 'tool self.keymaps tool: tool))
        (add-message! chat (let (message (new-assistant-message self.keymaps))
                             (add-message-part! message 0 'tool self.keymaps tool: tool)
                             message))))))

;; Pi settled: nothing it does goes on, so what is still open closes.
(def (settled! (self : pi-state) (chat : live-chat)) => :void
  (set! chat.busy? #f)
  (set! chat.retrying? #f)
  (for-each (lambda ((t : chat-tool))
              (when (eq? (chat-tool-state t) 'running) (finish-tool! t (make-hash-table) #t #f)))
            (hash-values chat.tools))
  (let (m chat.current)
    (when m
      (for-each (lambda ((p : message-part)) (finish-part! p self.keymaps)) (hash-values (chat-message-parts m)))
      (set! chat.current #f)))
  (request-stats! chat))

;;; Streaming

;; PART or TOOL got streamed text: drawn within 50 ms.
(def (dirty! (self : pi-state) (chat : live-chat) (what : :t)) => :void
  (unless (memq what chat.dirty)
    (set! chat.dirty (cons what chat.dirty)))
  (let (t chat.flush-timer)
    (if t
      (restart-timer t)
      (set! chat.flush-timer
        (context-run-with-timer! self.ctx 0.05 #f
                                 (lambda ()
                                   (when (pair? chat.dirty)
                                     (keeping-bottom! self chat
                                                      (lambda ()
                                                        (guarded! chat "drawing" (lambda () (flush! self chat)))
                                                        (draw-status! chat)))))
                                 name: 'pi-flush)))))

;; Draw what streamed and is not yet drawn.
(def (flush! (self : pi-state) (chat : live-chat)) => :void
  (let (dirty (reverse chat.dirty))
    (set! chat.dirty [])
    (for-each (lambda (what)
                (cond
                 ((message-part? what) (draw-part! what self.keymaps))
                 ((chat-tool? what)
                  (let (update (hash-get chat.updates (chat-tool-id what)))
                    (when update
                      (hash-remove! chat.updates (chat-tool-id what))
                      (set-tool-output! what update))))))
              dirty)))

;;; Pi stopping

;; Pi stopped (WHY), having written STDERR: shown once, with a Restart
;; button, and every waiting request fails.
(def (pi-stopped! (self : pi-state) (chat : live-chat) (why : :string) (stderr : :string)) => :void
  (unless chat.stopped
    (flush! self chat)
    (set! chat.stopped why)
    (set! chat.busy? #f)
    (set! chat.compacting? #f)
    (fail-pending! chat why)
    (let (l chat.link)
      (when l
        (let (c (helper-link-connected l)) (when c (close-connection! c)))))
    (keeping-bottom! self chat
                     (lambda ()
                       (notice! self chat
                                (let (tail (strip-ansi stderr))
                                  (if (string-empty? (one-line tail)) why (string-append why "\n" tail)))
                                'error
                                [(new-button "Restart" (lambda (b) (restart! self chat)))])))
    (draw-status! chat)
    (update-state! chat)))

;; A new helper for CHAT on its session file, after Pi stopped.
(def (restart! (self : pi-state) (chat : live-chat)) => :void
  (when (eq? (hash-get self.chats (pi-chat-id chat)) chat)
    (let (l chat.link)
      (when l
        (let (j (helper-link-reader l)) (when j (job-cancel! j)))
        (record-inbox-close! (helper-link-inbox l))))
    (start-helper! self chat (existing-session chat))
    (update-state! chat)))

;; Reload CHAT's Pi (Pilish's lesson): a new helper on the same session
;; file, which replaces the old one only once its Pi is up.
(def (reload! (self : pi-state) (chat : live-chat)) => :void
  (if (or chat.stopped (not chat.link))
    (restart! self chat)
    (let* ((id (random-id 8))
           (socket (helper-socket-path (socket-directory) id))
           (l (new-link id socket)))
      (set! chat.candidate l)
      (start-reader! self chat l (chat-launch chat id socket (existing-session chat))))))

;;; Extension dialogs

(def dialog-methods '("select" "confirm" "input" "editor"))

(def (ui-request! (self : pi-state) (chat : live-chat) (record : :t)) => :void
  (let ((method (json-field record "method"))
        (id (json-field record "id")))
    (cond
     ((and (member method dialog-methods) (string? id)) (ask-later! self chat id record))
     ((equal? method "notify")
      (let ((text (json-field record "message"))
            (kind (json-field record "notifyType")))
        (when (string? text)
          (message (string-append (cond ((equal? kind "error") "✗ ") ((equal? kind "warning") "⚠ ") (else ""))
                                  "Pi: " (strip-ansi text))))))
     ((equal? method "setStatus")
      (let ((key (json-field record "statusKey"))
            (text (json-field record "statusText")))
        (when (string? key)
          (set! chat.statuses (append (filter (lambda ((entry : :pair)) (not (equal? (car entry) key))) chat.statuses)
                                      (if (and (string? text) (not (string-empty? (strip-ansi text))))
                                        [(cons key (one-line (strip-ansi text) 60))]
                                        []))))))
     ((equal? method "set_editor_text")
      (let (text (json-field record "text"))
        (when (string? text) (set-prompt-text! chat text))))
     ;; Widgets and titles have no place in a chat.
     (else (void)))))

(def (question-text (request : :t)) => :string
  (let ((title (json-field request "title"))
        (body (json-field request "message"))
        (placeholder (json-field request "placeholder")))
    (string-append "Pi asks: " (if (string? title) (strip-ansi title) "")
                   (if (string? body) (string-append "\n" (strip-ansi body)) "")
                   (let (options (json-field request "options"))
                     (if (list? options) (string-append "\n" (string-join (filter string? options) " · ")) ""))
                   (if (string? placeholder) (string-append "\n(" placeholder ")") ""))))

;; Show Pi's dialog ID (REQUEST) in CHAT until it is answered, or its
;; timeout passes, when Pi gives up on it.
(def (ask-later! (self : pi-state) (chat : live-chat) (id : :string) (request : :t)) => :void
  (unless (find (lambda ((q : question)) (equal? (question-id q) id)) chat.questions)
    (let* ((node (new-node 'pi-question attributes: [(cons 'read-only #t)]
                           children: [(new-text-node (new-text (question-text request)))]
                           keymap: self.question-map))
           (q (question id: id request: request element: node timer: #f)))
      (set-node-children! node (append (node-children node)
                                       [(new-button "Answer" (lambda (b) (answer! self chat q)))]))
      (let (timeout (json-field request "timeout"))
        (when (and (real? timeout) (> timeout 0))
          (set! (question-timer q)
            (context-run-with-timer! self.ctx (/ timeout 1000.) #f
                                     (lambda ()
                                       (keeping-bottom! self chat (lambda () (drop-question! chat q)))
                                       (draw-status! chat)
                                       (update-state! chat))
                                     name: 'pi-question-timeout))))
      (set! chat.questions (cons q chat.questions))
      (refresh-root! chat))))

(def (drop-question! (chat : live-chat) (q : question)) => :void
  (let (t (question-timer q)) (when t (cancel-timer t)))
  (set! chat.questions (remq q chat.questions))
  (refresh-root! chat))

;; Ask Q in the minibuffer and send Pi the answer; C-g sends that it was
;; cancelled, as does a dialog Tuna cannot ask.
(def (answer! (self : pi-state) (chat : live-chat) (q : question)) => :void
  (let* ((request (question-request q))
         (method (json-field request "method"))
         (title (let (t (json-field request "title")) (if (string? t) (strip-ansi t) "Pi asks")))
         (reply (lambda ((fields : :list))
                  (when (memq q chat.questions)
                    (drop-question! chat q)
                    (let (record (hash ("type" "extension_ui_response") ("id" (question-id q))))
                      (for-each (lambda ((field : :pair)) (hash-put! record (car field) (cdr field))) fields)
                      (let (l chat.link) (when l (send-line! l record))))
                    (draw-status! chat)
                    (update-state! chat)))))
    (if (not (and (service-there? minibuffer-service) (service-there? completion-service)))
      (reply [(cons "cancelled" #t)])
      (with-catch
       (lambda (e)
         (when (quit-condition? e) (reply [(cons "cancelled" #t)]))
         (raise e))
       (lambda ()
         (reply
          (cond
           ((equal? method "select")
            (let (options (filter string? (or (json-field request "options") [])))
              [(cons "value" (completing-read (string-append title ": ")
                                              [(make-completion-table category: 'pi-choice
                                                                      items: (strings->candidates options))]
                                              default: (and (pair? options) (car options))))]))
           ((equal? method "confirm")
            (let (body (json-field request "message"))
              [(cons "confirmed"
                     (equal? "yes" (completing-read (string-append title (if (string? body) (string-append " " (strip-ansi body)) "") " ")
                                                    [(make-completion-table category: 'pi-choice
                                                                            items: (strings->candidates ["yes" "no"]))])))]))
           ((equal? method "input")
            [(cons "value" (read-string (string-append title ": ")))])
           (else
            ;; editor: prefilled, S-RET starts a new line.
            (let (prefill (json-field request "prefill"))
              [(cons "value" (read-from-minibuffer (string-append title ": ") (if (string? prefill) prefill "")
                                                   setup: (lambda (p)
                                                            (keymap-set-in! self.ctx (prompt-keymap p) "S-RET" 'pi-newline
                                                                            "plugins/pi/plugin.ss"))))])))))))))

;;; The prompt

(def (set-prompt-text! (chat : live-chat) (text : :string)) => :void
  (text-replace! chat.prompt 1 (fx1+ (text-size chat.prompt)) text)
  (for-each (lambda ((v : view))
              (when (eq? (view-node v) chat.prompt-node) (set-view-point! v (fx1+ (text-size chat.prompt)))))
            (views-showing chat)))

(def (focus-prompt! (chat : live-chat)) => :void
  (let (v (selected-view))
    (when (eq? (view-showing v) (pi-chat-buffer chat))
      (set-view-focus! v chat.prompt-node (fx1+ (text-size chat.prompt))))))

;; Send TEXT to CHAT's Pi as the user's message: queued as a follow-up
;; while Pi works, a steer with STEER?; back in the prompt if Pi refuses
;; it. A prompt sent while Pi is idle makes it busy at once, so the next
;; one queues, unless Pi answers that it handled it without a run.
(def (send-text! (self : pi-state) (chat : live-chat) (text : :string) (steer? : :boolean)) => :void
  (let ((busy? (or chat.busy? chat.compacting?)))
    (unless busy? (set! chat.busy? #t))
    (request! chat
              (let (record (hash ("type" (if (and steer? busy?) "steer" "prompt")) ("message" text)))
                (when (and busy? (not steer?)) (hash-put! record "streamingBehavior" "followUp"))
                record)
              (lambda (response)
                (cond
                 ((not (response-ok? response))
                  (unless busy? (set! chat.busy? #f))
                  (message (string-append "Pi: " (response-error response)))
                  (when (string-empty? (text-string chat.prompt))
                    (set-prompt-text! chat text)))
                 ((and (not busy?) (equal? (json-field (response-data response) "disposition") "handled"))
                  (set! chat.busy? #f)))
                (draw-status! chat)
                (update-state! chat)))
    (draw-status! chat)
    (update-state! chat)))

(def (send-prompt! (self : pi-state) (chat : live-chat) (steer? : :boolean)) => :void
  (let (text (text-string chat.prompt))
    (unless (string-empty? (one-line text))
      (set! chat.history (cons text (filter (lambda (h) (not (equal? h text))) chat.history)))
      (set! chat.history-index #f)
      (set! chat.draft "")
      (set-prompt-text! chat "")
      (text-clear-undo! chat.prompt)
      (send-text! self chat text steer?)
      (for-each (cut place-at-bottom! chat <>) (filter (lambda ((v : view)) (eq? v (selected-view))) (views-showing chat))))))

;; Stop Pi: what is queued goes back to the prompt, then Pi aborts.
(def (abort! (self : pi-state) (chat : live-chat)) => :void
  (request! chat (hash ("type" "clear_queue"))
            (lambda (response)
              (when (response-ok? response)
                (let* ((data (response-data response))
                       (queued (filter string? (append (or (json-field data "steering") []) (or (json-field data "followUp") [])))))
                  (when (pair? queued)
                    (set-prompt-text! chat (string-join (cons (text-string chat.prompt) queued) "\n")))))))
  (request! chat (hash ("type" "abort"))))

(def (history-step! (chat : live-chat) (step : :fixnum)) => :void
  (let (index (fx+ (or chat.history-index -1) step))
    (cond
     ((fx< index -1) (message "End of history"))
     ((fx>= index (length chat.history)) (message "Beginning of history"))
     (else
      (unless chat.history-index (set! chat.draft (text-string chat.prompt)))
      (set! chat.history-index (if (fx= index -1) #f index))
      (set-prompt-text! chat (if (fx= index -1) chat.draft (list-ref chat.history index)))))))

;;; The transcript at point

;; The nearest node at or above N of KIND, or #f.
(def (ancestor-of-kind (n :? node) (kind : :symbol)) => (Maybe node)
  (let up ((m n))
    (and m (if (eq? (node-kind m) kind) m (up (node-parent m))))))

(def (tool-of-node (chat : live-chat) (n : node)) => (Maybe chat-tool)
  (find (lambda ((t : chat-tool)) (eq? (chat-tool-element t) n)) (hash-values chat.tools)))

(def (thinking-of-node (chat : live-chat) (n : node)) => (Maybe message-part)
  (ormap (lambda ((m : chat-message))
           (find (lambda ((p : message-part)) (eq? (message-part-element p) n)) (hash-values (chat-message-parts m))))
         chat.messages))

;; Fold or unfold the tool or thinking block holding N, keeping the
;; selected view's focus in the chat.
(def (toggle-at! (self : pi-state) (chat : live-chat) (n :? node)) => :void
  (let ((tool-node (ancestor-of-kind n 'pi-tool))
        (thinking-node (ancestor-of-kind n 'pi-thinking)))
    (cond
     ((and tool-node (tool-of-node chat tool-node)) => toggle-tool!)
     ((and thinking-node (thinking-of-node chat thinking-node))
      => (lambda (part)
           (toggle-thinking! part self.keymaps)
           (let (v (selected-view))
             (when (and (eq? (view-showing v) (pi-chat-buffer chat))
                        (not (under-root? chat (view-node v))))
               (set-view-focus! v (first-text-node thinking-node) 1)))))
     (else (message "Nothing to fold here")))))

(def (under-root? (chat : live-chat) (n :? node)) => :boolean
  (let up ((m n))
    (cond ((not m) #f) ((eq? m chat.root) #t) (else (up (node-parent m))))))

;; Open the file at point: FILE:LINE in the line, else the file of the
;; tool whose header point is in.
(def (open-at-point! (self : pi-state) (chat : live-chat)) => :void
  (let* ((n (current-text-node))
         (directory (pi-chat-directory chat))
         (absolute (lambda ((path : :string)) (if (string-prefix? "/" path) path (path-expand path directory))))
         (reference (and n
                         (let* ((t (text-node-content n))
                                (position (point))
                                (line (text-line-at t position))
                                (start (text-line-start t line))
                                (column (fx- position start))
                                (text (text-substring t start (text-line-end t line))))
                           (find (lambda ((r : :list)) (and (fx<= (car r) column) (fx<= column (cadr r))))
                                 (find-file-references text (lambda ((p : :string)) (file-exists? (absolute p))))))))
         (header (ancestor-of-kind n 'pi-header))
         (tool-node (and header (ancestor-of-kind header 'pi-tool)))
         (tool (and tool-node (tool-of-node chat tool-node))))
    (cond
     ((not (service-there? files-service)) (message "Opening files needs the files plugin"))
     (reference
      (find-file-at-line (absolute (list-ref reference 2))
                         (let (l (list-ref reference 3)) (and l (string->number l)))
                         (let (c (list-ref reference 4)) (and c (string->number c)))))
     ((and tool (chat-tool-path tool))
      => (lambda (path)
           (let (offset (json-field (chat-tool-args tool) "offset"))
             (find-file-at-line (absolute path) (or (chat-tool-line tool) (and (fixnum? offset) offset)) #f))))
     (else (message "No file here")))))

;; Move to the next (STEP 1) or previous (-1) message of yours.
(def (goto-user-message! (chat : live-chat) (step : :fixnum)) => :void
  (let* ((users (filter (lambda ((m : chat-message)) (eq? (chat-message-role m) 'user)) (reverse chat.messages)))
         (nodes (map chat-message-element users))
         (here (ancestor-of-kind (current-text-node) 'pi-message))
         (ordered (if (fx> step 0) nodes (reverse nodes)))
         (all (map chat-message-element (reverse chat.messages)))
         (index-of (lambda (n) (let lp ((l all) (i 0)) (cond ((null? l) -1) ((eq? (car l) n) i) (else (lp (cdr l) (fx1+ i)))))))
         (here-index (if here (index-of here) (length all)))
         (target (find (lambda (n) (if (fx> step 0) (fx> (index-of n) here-index) (fx< (index-of n) here-index)))
                       ordered)))
    (if target
      (set-view-focus! (selected-view) (first-text-node target) 1)
      (message (if (fx> step 0) "No later message of yours" "No earlier message of yours")))))

;;; Starting chats

(def (start-chat! (self : pi-state) (directory : :string)) => live-chat
  (let* ((id (random-id 8))
         (chat (new-live-chat self id (unique-buffer-name (chat-name directory)) directory)))
    (switch-to-buffer (pi-chat-buffer chat))
    (focus-prompt! chat)
    (start-helper! self chat #f)
    (for-each (cut place-at-bottom! chat <>) (views-showing chat))
    chat))

(def (current-project) => :string
  (project-directory (buffer-default-directory (current-buffer))))

(def (open-chat! (self : pi-state)) => :void
  (let* ((directory (current-project))
         (chat (find (lambda ((c : live-chat)) (equal? (pi-chat-directory c) directory)) (reverse self.order))))
    (if chat
      (begin
        (switch-to-buffer (pi-chat-buffer chat))
        (focus-prompt! chat))
      (start-chat! self directory))))

(def (chat-busy? (chat : live-chat)) => :boolean
  (and (not chat.stopped) (or chat.busy? chat.compacting? (pair? chat.questions))))

(def (yes-or-no? (question : :string)) => :boolean
  (let lp ()
    (let (answer (read-string (string-append question "(yes or no) ")))
      (cond
       ((equal? answer "yes") #t)
       ((equal? answer "no") #f)
       (else (message "Please answer yes or no.") (lp))))))

;; Forget CHAT, its buffer killed: end its Pi and helper when KILL?, else
;; leave them running (Tuna stopping, the plugin turning off).
(def (forget! (self : pi-state) (chat : live-chat) (kill? : :boolean)) => :void
  (hash-remove! self.chats (pi-chat-id chat))
  (hash-remove! self.by-buffer (pi-chat-buffer chat))
  (set! self.order (remq chat self.order))
  (for-each (lambda ((l :? helper-link))
              (when l
                (let (c (helper-link-connected l))
                  (when c
                    (connection-send! c (hash ("type" (if kill? "helper_kill" "helper_detach"))))
                    (close-connection! c)))
                (let (j (helper-link-reader l)) (when j (job-cancel! j)))
                (record-inbox-close! (helper-link-inbox l))))
            [chat.link chat.candidate])
  (for-each (lambda ((q : question)) (let (t (question-timer q)) (when t (cancel-timer t)))) chat.questions)
  (let (t chat.flush-timer) (when t (cancel-timer t)))
  (fail-pending! chat "The chat was closed"))

;;; The session

;; Each chat: (ID SOCKET BUFFER-NAME SESSION-FILE DIRECTORY DRAFT HISTORY).
(def (save-chats (self : pi-state)) => :list
  (map (lambda ((chat : live-chat))
         (let (l chat.link)
           [(pi-chat-id chat) (if l (helper-link-socket l) "") (buffer-name (pi-chat-buffer chat))
            (or chat.session-file "") (pi-chat-directory chat) (text-string chat.prompt)
            (take chat.history (fxmin 100 (length chat.history)))]))
       (reverse self.order)))

(def (restore-chats! (self : pi-state) (data : :t)) => :void
  (when (list? data)
    (for-each
     (lambda (entry)
       (match entry
         ([(? string? id) (? string? socket) (? string? name) (? string? session) (? string? directory)
           (? string? draft) (? list? history)]
          (unless (hash-get self.chats id)
            (let (chat (new-live-chat self id (unique-buffer-name name) directory))
              (set! (live-chat-session-file chat) (and (not (string-empty? session)) session))
              (set! (live-chat-history chat) (filter string? history))
              (text-replace! (live-chat-prompt chat) 1 1 draft)
              (text-clear-undo! (live-chat-prompt chat))
              (if (string-empty? socket)
                (start-helper! self chat (existing-session chat))
                (let (l (new-link (path-strip-extension (path-strip-directory socket)) socket))
                  (set! (live-chat-link chat) l)
                  (start-reader! self chat l #f))))))
         (else (void))))
     data)))

;;; The service

(defclass pi-provider ((state : pi-state)) final: #t)

(implement Pi pi-provider
  (chats (lambda (self) (reverse (pi-state-order self.state))))
  (add-to-prompt! (lambda (self chat text)
                    (using (chat : live-chat)
                      (text-replace! chat.prompt (fx1+ (text-size chat.prompt)) (fx1+ (text-size chat.prompt)) text))))
  (send! (lambda (self chat text) (send-text! self.state chat text #f))))

;;; Drawing nodes

(def (render-status (n : node)) => :t
  `(div (@ (class "pi-status") (role "status"))
        ,@(map (lambda ((part : :string)) `(span (@ (class "pi-status-part")) ,part)) (node-attribute n 'parts))))

(def (render-role (n : node)) => :t
  (let (role (node-attribute n 'role))
    `(div (@ (class "pi-role") (data-role ,(symbol->string role)))
          ,(case role ((user) "You") ((assistant) "Pi") (else "Tuna")))))

;;; Options

(def string-list-type
  (make-option-type "a list of strings, a program and its arguments, as (\"pi\")"
                    (lambda (v) (and (pair? v) (list? v) (andmap string? v)))
                    (lambda (text) (string-split text #\space))))

(def model-type
  (make-option-type "a model as \"provider/id\", or #f for Pi's own" (lambda (v) (or (not v) (string? v)))
                    (lambda (text) (if (equal? text "#f") #f text))))

(def thinking-type
  (make-option-type "a thinking level: off, minimal, low, medium, high, xhigh or max, or #f for Pi's own"
                    (lambda (v) (or (not v) (memq v '(off minimal low medium high xhigh max))))
                    (lambda (text) (if (equal? text "#f") #f (string->symbol text)))))

(def trust-type
  (make-option-type "approve, default or no-approve" (cut memq <> '(approve default no-approve)) string->symbol))

(def scope-type
  (make-option-type "auto, always or never" (cut memq <> '(auto always never)) string->symbol))

(defplugin (pi ctx)
  "M-x pi: a chat with the Pi coding agent, in a helper process that survives Tuna restarting."
  provides: [pi-service]
  requires: [commands-service input-service settings-service buffers-service session-service markdown-service]
  optional: [layout-service minibuffer-service completion-service completion-ui-service files-service file-system-service
             program-status-service]
  (add-stylesheet 'tokens "tokens.css")
  (add-stylesheet 'rules "rules.css")
  (using (self (pi-state ctx: ctx chats: (make-hash-table) by-buffer: (make-hash-table-eq) order: []
                         jobs: (new-job-group ctx)
                         keymaps: (make-transcript-keymaps (new-keymap) (new-keymap))
                         prompt-map: (new-keymap) question-map: (new-keymap)
                         clients: [] waiting: [] stopping?: #f)
               : pi-state)
    (context-define-node-kind! ctx 'pi-chat doc: "A Pi chat: its messages, questions, status bar and prompt."
                               items: 'children)
    (context-define-node-kind! ctx 'pi-message doc: "One message of a Pi chat: yours, Pi's, or Tuna's notice."
                               items: 'children)
    (context-define-node-kind! ctx 'pi-role doc: "Who wrote a message." items: 'whole
                               project: (lambda (n) (case (node-attribute n 'role) ((user) "You") ((assistant) "Pi") (else ""))))
    (context-define-node-kind! ctx 'pi-text doc: "Pi's text, as Markdown blocks." items: 'children)
    (context-define-node-kind! ctx 'pi-thinking doc: "Pi's thinking, folded once done." items: 'children)
    (context-define-node-kind! ctx 'pi-thinking-text doc: "The text of Pi's thinking." items: 'children)
    (context-define-node-kind! ctx 'pi-header doc: "The header of a tool or thinking block; a click folds it."
                               items: 'children)
    (context-define-node-kind! ctx 'pi-tool doc: "A tool call: its header, then its output." items: 'children)
    (context-define-node-kind! ctx 'pi-tool-body doc: "A tool's output, or an edit's diff." items: 'children)
    (context-define-node-kind! ctx 'pi-notice doc: "A notice from the chat, such as Pi having stopped." items: 'children)
    (context-define-node-kind! ctx 'pi-question doc: "A question from a Pi extension, waiting for an answer."
                               items: 'children)
    (context-define-node-kind! ctx 'pi-status doc: "A chat's status bar." items: 'whole
                               project: (lambda (n) (string-join (node-attribute n 'parts) " · ")))
    (context-define-node-kind! ctx 'pi-prompt doc: "A chat's prompt." items: 'children)
    (for-each (lambda ((kind : :symbol))
                (let (class (symbol->string kind))
                  (context-define-node-renderer! ctx kind (lambda (n children) `(div (@ (class ,class)) ,@children)))))
              '(pi-chat pi-text pi-thinking-text pi-header pi-tool-body pi-prompt))
    (context-define-node-renderer! ctx 'pi-message
                                   (lambda (n children)
                                     `(section (@ (class "pi-message") (data-role ,(symbol->string (node-attribute n 'role))))
                                               ,@children)))
    (context-define-node-renderer! ctx 'pi-thinking
                                   (lambda (n children)
                                     `(div (@ (class "pi-thinking") ,@(if (node-attribute n 'folded) '((data-folded "")) '()))
                                           ,@children)))
    (context-define-node-renderer! ctx 'pi-tool
                                   (lambda (n children)
                                     `(div (@ (class "pi-tool") (data-state ,(symbol->string (node-attribute n 'state)))
                                              ,@(if (node-attribute n 'folded) '((data-folded "")) '()))
                                           ,@children)))
    (context-define-node-renderer! ctx 'pi-notice
                                   (lambda (n children)
                                     `(div (@ (class "pi-notice") (data-level ,(symbol->string (node-attribute n 'level))))
                                           ,@children)))
    (context-define-node-renderer! ctx 'pi-question
                                   (lambda (n children) `(div (@ (class "pi-question") (role "alert")) ,@children)))
    (context-define-node-renderer! ctx 'pi-status (lambda (n children) (render-status n)))
    (context-define-node-renderer! ctx 'pi-role (lambda (n children) (render-role n)))

    (context-add-hook! ctx kill-buffer-hook 'pi
                       (lambda (b)
                         (let (chat (hash-get self.by-buffer b))
                           (when chat (forget! self chat (not self.stopping?))))))
    (context-add-kill-buffer-query! ctx 'pi
                                    (lambda (b)
                                      (let (chat (hash-get self.by-buffer b))
                                        (or (not chat) (not (chat-busy? chat))
                                            (not (service-there? minibuffer-service))
                                            (yes-or-no? (string-append "Pi is working in " (buffer-name b) "; stop it? "))))))
    (context-add-hook! ctx post-command-hook 'pi
                       (lambda ()
                         (let (c (current-client))
                           (when (and c (current-chat self) (not (memq c self.clients)))
                             (set! self.clients (cons c self.clients))))))
    (context-add-hook! ctx client-gone-hook 'pi (lambda (c) (set! self.clients (remq c self.clients))))
    (context-add-hook! ctx task-started-hook 'pi
                       (lambda (id name)
                         (let (waiting self.waiting)
                           (when (pair? waiting)
                             (set! self.waiting [])
                             (for-each (lambda ((entry : :pair))
                                         (let ((chat (car entry)) (l (cdr entry)))
                                           (when (eq? (live-chat-link chat) l)
                                             (start-reader! self chat l #f))))
                                       (reverse waiting))))))
    (context-add-session-slot! ctx 'pi-chats version: 1
                               save: (lambda () (save-chats self))
                               restore: (lambda (data) (restore-chats! self data)))

    ;; Commands
    (define-command ctx (pi) "Show the Pi chat of the current buffer's project (its git root, else its folder), starting one when there is none."
      (open-chat! self))
    (define-command ctx (pi-new) "Start a new Pi chat in the current buffer's project."
      (start-chat! self (current-project)))
    (define-command ctx (pi-send) "Send the prompt to Pi; while Pi works, it is queued until Pi is done."
      (send-prompt! self (this-chat self) #f))
    (define-command ctx (pi-steer) "Send the prompt to Pi to read after its current tool (a steer); when Pi is idle, send it."
      (send-prompt! self (this-chat self) #t))
    (define-command ctx (pi-newline) "Start a new line in the prompt."
      (insert "\n"))
    (define-command ctx (pi-abort) "Stop Pi; what was queued comes back to the prompt."
      (abort! self (this-chat self)))
    (define-command ctx (pi-previous-prompt) "Show the prompt sent before the one shown."
      (history-step! (this-chat self) 1))
    (define-command ctx (pi-next-prompt) "Show the prompt sent after the one shown."
      (history-step! (this-chat self) -1))
    (define-command ctx (pi-toggle) "Fold or unfold the tool or thinking block at point."
      (toggle-at! self (this-chat self) (current-text-node)))
    (define-command ctx (pi-toggle-clicked) "Fold or unfold the tool or thinking block clicked."
      (let* ((p (event-start (last-command-event)))
             (n (and p (service-there? layout-service) (posn-node p)))
             (chat (and n (find (lambda ((c : live-chat)) (under-root? c n)) self.order))))
        (when chat (toggle-at! self chat n))))
    (define-command ctx (pi-open-at-point) "Open the file at point: FILE:LINE in a tool's output, or the file of the tool whose header point is in."
      (open-at-point! self (this-chat self)))
    (define-command ctx (pi-next-message) "Move to your next message."
      (goto-user-message! (this-chat self) 1))
    (define-command ctx (pi-previous-message) "Move to your previous message."
      (goto-user-message! (this-chat self) -1))
    (define-command ctx (pi-answer) "Answer the question Pi's extension asks here, or the newest one."
      (let* ((chat (this-chat self))
             (questions (live-chat-questions chat))
             (here (ancestor-of-kind (current-text-node) 'pi-question))
             (q (or (and here (find (lambda ((q : question)) (eq? (question-element q) here)) questions))
                    (and (pair? questions) (car questions)))))
        (if q (answer! self chat q) (message "No question waits"))))
    (define-command ctx (pi-restart) "Start the chat's Pi again, on its session."
      (restart! self (this-chat self)))
    (define-command ctx (pi-reload) "Start a new Pi on the chat's session; it replaces the old one once it is up."
      (reload! self (this-chat self)))

    ;; Keymaps
    (let (bind (lambda ((keymap : entry-table) (keys : :string) (command : :symbol))
                 (keymap-set-in! ctx keymap keys command "plugins/pi/plugin.ss")))
      (for-each (lambda ((binding : :pair)) (bind self.prompt-map (car binding) (cdr binding)))
                '(("RET" . pi-send) ("S-RET" . pi-newline) ("M-RET" . pi-steer) ("C-c C-k" . pi-abort)
                  ("M-p" . pi-previous-prompt) ("M-n" . pi-next-prompt)))
      (for-each (lambda ((binding : :pair)) (bind (transcript-keymaps-message self.keymaps) (car binding) (cdr binding)))
                '(("TAB" . pi-toggle) ("RET" . pi-open-at-point) ("n" . pi-next-message) ("p" . pi-previous-message)
                  ("C-c C-k" . pi-abort)))
      (bind (transcript-keymaps-header self.keymaps) "<mouse-1>" 'pi-toggle-clicked)
      (for-each (lambda ((binding : :pair)) (bind self.question-map (car binding) (cdr binding)))
                '(("RET" . pi-answer) ("C-c C-k" . pi-abort))))

    (context-provide! ctx pi-service (Pi (pi-provider state: self)))

    ;; Turning off leaves every helper running: it is how a swap, a reload
    ;; or Tuna stopping keep their Pis.
    (context-defer! ctx
                    (lambda ()
                      (set! self.stopping? #t)
                      (for-each (lambda ((chat : live-chat))
                                  (let (b (pi-chat-buffer chat))
                                    (forget! self chat #f)
                                    (with-catch void (lambda () (kill-buffer b)))))
                                (hash-values self.chats))))))

(defplugin-options pi
  (pi-command ["pi"]
              "The program that runs Pi and its first arguments; the helper adds --mode rpc and the rest."
              string-list-type)
  (model #f
         "The model new chats start with, as \"provider/id\"; #f for Pi's own default."
         model-type)
  (thinking 'low
            "The thinking level new chats start with; #f for Pi's own default."
            thinking-type)
  (trust 'approve
         "Whether Pi trusts the project's own Pi files: approve (--approve), default, or no-approve (--no-approve)."
         trust-type)
  (idle-exit 60
             "Seconds a helper waits, with no Tuna connected and Pi idle, before it ends Pi and itself."
             (integer-type 1 86400))
  (helper default-helper-path
          "The Pi helper program; `make` builds it into .gerbil/bin."
          string-type)
  (socket-directory ""
                    "The private folder holding helpers' sockets; \"\" for $XDG_RUNTIME_DIR/tuna/pi."
                    string-type)
  (leave-scope 'auto
               "Whether helpers leave Tuna's systemd scope or service, which would kill them with it: auto (when Tuna runs in one), always or never."
               scope-type))
