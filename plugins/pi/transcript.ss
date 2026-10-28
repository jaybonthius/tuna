;;; A chat's transcript as buffer nodes (docs/briefs/2026-10-pi-chat.md):
;;; each message a `pi-message` node, read-only (the buffers contract's
;;; `read-only` attribute), so the cursor moves through it and it can be
;;; selected and copied, but only the prompt is edited. Your messages and
;;; Pi's text are Markdown (the markdown contract), in a proportional
;;; font; Pi's thinking is plain text, shown while it streams and folded
;;; once done; each tool call is a block, its header the tool's name and
;;; key argument, how long it took and whether it failed, its body a
;;; preview of its output (10 lines, 5 of a command's, the last ones),
;;; all of it once unfolded; an edit shows its −/+ diff. The plugin
;;; defines and draws the kinds (plugin.ss); this file makes and changes
;;; the nodes, from Pi's messages (JSON values) and streamed parts.
prelude: :gerbil/core

(import (only-in :gerbil/runtime/hash HashTable)
        :tuna/kernel
        :tuna/plugins/buffers/contract
        :tuna/plugins/markdown/contract
        ./jsonl
        ./tool-text)
(export (struct-out transcript-keymaps)
        chat-message chat-message? chat-message-role chat-message-element chat-message-parts
        message-part message-part? message-part-kind message-part-element message-part-text
        message-part-tool message-part-done?
        chat-tool chat-tool? chat-tool-id chat-tool-name chat-tool-args chat-tool-element chat-tool-state
        chat-tool-path chat-tool-line chat-tool-header chat-tool-body chat-tool-folded?
        new-role-message
        new-notice
        notice-node
        new-assistant-message
        message-part-at
        add-message-part!
        append-part-text!
        set-part-text!
        finish-part!
        draw-part!
        replace-assistant-content!
        set-message-error!
        new-tool
        set-tool-args!
        start-tool!
        set-tool-output!
        finish-tool!
        toggle-tool!
        toggle-thinking!
        history-message
        assistant-error
        preview-lines
        preview-bytes
        expanded-bytes)

;; Lines a tool's folded body shows, and a command's (its last ones).
(def preview-lines 10)
(def command-preview-lines 5)
;; Characters of output a folded body shows at most, and an unfolded one.
(def preview-bytes 4096)
(def expanded-bytes 200000)

;; The keymaps the transcript's nodes carry: MESSAGE, on each message (TAB,
;; RET, n, p); HEADER, on the header of a tool or thinking block (a click
;; folds it).
(defstruct transcript-keymaps ((message : entry-table) (header : entry-table)) final: #t)

;; One tool call: ID (Pi's toolCallId), NAME and ARGS (JSON); its node
;; (`pi-tool`), its header and body nodes and their texts, the body shown
;; only when there is something in it; STATE 'called (no result yet),
;; 'running, 'ok or 'error; when it started (seconds) and how long it took
;; (ms) once known; its output, as Pi last gave it; FOLDED?, whether the
;; body shows only a preview; LINE, the line an edit changed first.
(defclass chat-tool ((id       : :string)
                     (name     : :string)
                     (args     : :t)
                     (element  : node)
                     (header-node : node)
                     (header   : text)
                     (body-node : node)
                     (body     : text)
                     (state    : :symbol)
                     (started  :? :real)
                     (duration :? :real)
                     (output   : :string)
                     (line     :? :fixnum)
                     (folded?  : :boolean))
  final: #t)

;; One part of Pi's message, by its content index: KIND 'text, 'thinking
;; or 'tool; its node; TEXT, all of a text or thinking part so far (what
;; streamed, or what its end said); DONE?, whether it ended; a thinking
;; part's FOLDED?; a tool part's TOOL.
(defclass message-part ((kind    : :symbol)
                        (element : node)
                        (text    : :string)
                        (drawn   : :string)
                        (done?   : :boolean)
                        (folded? : :boolean)
                        (tool    :? chat-tool))
  final: #t)

;; One message: ROLE 'user, 'assistant or 'notice; its node; an assistant
;; message's PARTS, content index -> message-part.
(defclass chat-message ((role  : :symbol)
                        (element : node)
                        (parts : HashTable))
  final: #t)

(def (wrapped (kind : :symbol) (t : text) (attributes : :list := [])) => node
  (new-node kind attributes: attributes children: [(new-text-node t)]))

;; The label of a message of ROLE: who wrote it; none for a notice.
(def (role-labels (role : :symbol)) => :list
  (if (memq role '(user assistant)) [(new-node 'pi-role attributes: [(cons 'role role)])] []))

;; A message node of ROLE holding CHILDREN after its label.
(def (message-node (role : :symbol) (children : :list) (keymaps : transcript-keymaps)) => node
  (new-node 'pi-message attributes: [(cons 'role role) (cons 'read-only #t)]
            children: (append (role-labels role) children)
            keymap: (transcript-keymaps-message keymaps)))

;; A message of ROLE ('user, or 'notice) whose text is MARKDOWN.
(def (new-role-message (role : :symbol) (markdown : :string) (keymaps : transcript-keymaps)) => chat-message
  (chat-message role: role element: (message-node role (markdown-blocks markdown) keymaps)
                parts: (make-hash-table)))

;; A notice from the chat itself, such as Pi having stopped: its text,
;; plain, a `pi-notice` of LEVEL ('info or 'error), then EXTRA nodes
;; (buttons).
(def (notice-node (text : :string) (level : :symbol) (extra : :list := [])) => node
  (new-node 'pi-notice attributes: [(cons 'level level)]
            children: (cons (new-text-node (new-text text)) extra)))

(def (new-notice (text : :string) (level : :symbol) (keymaps : transcript-keymaps) (extra : :list := []))
  => chat-message
  (chat-message role: 'notice element: (message-node 'notice [(notice-node text level extra)] keymaps)
                parts: (make-hash-table)))

(def (new-assistant-message (keymaps : transcript-keymaps)) => chat-message
  (chat-message role: 'assistant element: (message-node 'assistant [] keymaps) parts: (make-hash-table)))

(def (message-part-at (m : chat-message) (index : :fixnum)) => (Maybe message-part)
  (hash-get m.parts index))

;; M's node's children: its label, then its parts by content index, then
;; its error, if any.
(def (refresh-message! (m : chat-message)) => :void
  (let* ((indices (list-sort < (hash-keys m.parts)))
         (error (node-attribute m.element 'error)))
    (set-node-children! m.element
                        (append (role-labels m.role)
                                (map (lambda (i) (message-part-element (hash-ref m.parts i))) indices)
                                (if error [(notice-node error 'error)] [])))))

;; Add a part of KIND at content INDEX to M, a tool part showing TOOL.
(def (add-message-part! (m : chat-message) (index : :fixnum) (kind : :symbol) (keymaps : transcript-keymaps)
                        tool: (tool :? chat-tool := #f))
  => message-part
  (let (part (message-part kind: kind
                           element: (case kind
                                   ((tool) (chat-tool-element tool))
                                   ((thinking) (thinking-node "" #f #f keymaps))
                                   (else (new-node 'pi-text)))
                           text: "" drawn: "" done?: #f folded?: #f tool: tool))
    (hash-put! m.parts index part)
    (refresh-message! m)
    part))

;; Add streamed DELTA to text or thinking PART; drawn by draw-part!.
(def (append-part-text! (part : message-part) (delta : :string)) => :void
  (set! part.text (string-append part.text delta)))

(def (set-part-text! (part : message-part) (text : :string)) => :void
  (set! part.text text))

;; PART ended: a thinking part folds.
(def (finish-part! (part : message-part) (keymaps : transcript-keymaps)) => :void
  (unless part.done?
    (set! part.done? #t)
    (when (eq? part.kind 'thinking) (set! part.folded? #t))
    (set! part.drawn "")
    (draw-part! part keymaps)))

;;; Thinking

(def (thinking-header (text : :string) (done? : :boolean) (folded? : :boolean)) => :string
  (let (lines (if (string-empty? text) 0 (length (string-split text #\newline))))
    (cond
     ((not done?) "Thinking…")
     (folded? (string-append "▸ Thinking  (" (number->string lines) (if (fx= lines 1) " line)" " lines)")))
     (else "▾ Thinking"))))

(def (thinking-node (text : :string) (done? : :boolean) (folded? : :boolean) (keymaps : transcript-keymaps)) => node
  (new-node 'pi-thinking
            attributes: [(cons 'folded folded?)]
            children: (thinking-children text done? folded? keymaps)))

(def (thinking-children (text : :string) (done? : :boolean) (folded? : :boolean) (keymaps : transcript-keymaps))
  => :list
  (cons (new-node 'pi-header children: [(new-text-node (new-text (thinking-header text done? folded?)))]
                  keymap: (transcript-keymaps-header keymaps))
        (if folded? [] [(wrapped 'pi-thinking-text (new-text text))])))

;; Draw PART as its text now is, when that is not what it shows.
(def (draw-part! (part : message-part) (keymaps : transcript-keymaps)) => :void
  (unless (equal? part.text part.drawn)
    (case part.kind
      ((text)
       (set-node-children! part.element (markdown-update-blocks (node-children part.element) part.text)))
      ((thinking)
       (let* ((children (node-children part.element))
              (body (and (pair? children) (pair? (cdr children)) (first-text-node (cadr children))))
              (old part.drawn))
         (if (and body (not part.done?) (not part.folded?) (string-prefix? old part.text)
                  (fx= (text-size (text-node-content body)) (string-length old)))
           ;; Streaming: add what is new to the end.
           (let (t (text-node-content body))
             (text-replace! t (fx1+ (text-size t)) (fx1+ (text-size t))
                            (substring part.text (string-length old) (string-length part.text))))
           (begin
             (set-node-attribute! part.element 'folded part.folded?)
             (set-node-children! part.element (thinking-children part.text part.done? part.folded? keymaps))))))
      (else (void)))
    (set! part.drawn part.text)))

(def (toggle-thinking! (part : message-part) (keymaps : transcript-keymaps)) => :void
  (when part.done?
    (set! part.folded? (not part.folded?))
    (set! part.drawn "")
    (draw-part! part keymaps)))

;;; Pi's message as it ended

;; Make M's parts what CONTENT, the content of Pi's finished message, says,
;; keeping the nodes of parts that are the same kind. TOOL-FOR makes or
;; finds the tool of a toolCall block (id name args).
(def (replace-assistant-content! (m : chat-message) (content : :t) (keymaps : transcript-keymaps)
                                 (tool-for : :procedure))
  => :void
  (let lp ((blocks (if (list? content) content [])) (index 0))
    (match blocks
      ([] (for-each (lambda (i) (when (fx>= i index) (hash-remove! m.parts i))) (hash-keys m.parts)))
      ([block . more]
       (let* ((type (json-field block "type"))
              (kind (cond ((equal? type "text") 'text) ((equal? type "thinking") 'thinking)
                          ((equal? type "toolCall") 'tool) (else #f))))
         (when kind
           (let* ((old (hash-get m.parts index))
                  (tool (and (eq? kind 'tool)
                             (tool-for (or (json-field block "id") "") (or (json-field block "name") "tool")
                                       (json-field block "arguments"))))
                  (part (if (and old (eq? (message-part-kind old) kind)
                                 (or (not tool) (eq? (message-part-tool old) tool)))
                          old
                          (add-message-part! m index kind keymaps tool: tool))))
             (case kind
               ((text) (set-part-text! part (or (json-field block "text") "")))
               ((thinking) (set-part-text! part (or (json-field block "thinking") "")))
               (else (void)))
             (finish-part! part keymaps)
             (draw-part! part keymaps)))
         (lp more (fx1+ index))))))
  (refresh-message! m))

;; Show ERROR (#f for none) at the end of M, as an aborted or failed
;; reply's reason.
(def (set-message-error! (m : chat-message) (error :? :string)) => :void
  (set-node-attribute! m.element 'error error)
  (refresh-message! m))

;;; Tools

(def (tool-header-text (tool : chat-tool)) => :string
  (let* ((argument (tool-key-argument tool.name tool.args))
         (diff-counts (if (equal? tool.name "edit")
                        (let-values (((diff added removed) (edit-diff tool.args)))
                          (if (string-empty? diff) ""
                              (string-append "  +" (number->string added) " −" (number->string removed))))
                        ""))
         (time (if tool.duration (string-append "  " (duration-text tool.duration)) ""))
         (mark (case tool.state
                 ((running) "  …")
                 ((ok error) (string-append (if tool.duration " " "  ") (if (eq? tool.state 'ok) "✓" "✗")))
                 (else ""))))
    (string-append (if tool.folded? "▸ " "▾ ") tool.name (if (string-empty? argument) "" "  ") argument
                   diff-counts time mark)))

;; Highlight spans of a header TEXT for TOOL: the name, the argument, and
;; what follows it.
(def (tool-header-spans (tool : chat-tool) (text : :string)) => :list
  (let* ((name-start 3)
         (name-end (fx+ name-start (string-length tool.name)))
         (argument (tool-key-argument tool.name tool.args))
         (argument-end (if (string-empty? argument) name-end (fx+ name-end 2 (string-length argument))))
         (size (fx1+ (string-length text))))
    (filter (lambda ((s : span)) (fx< (span-start s) (span-end s)))
            [(make-span name-start name-end 'pi-tool-name)
             (make-span (fxmin size (fx+ name-end 2)) (fxmin size argument-end) 'pi-tool-argument)
             (make-span (fxmin size argument-end) size
                        (case tool.state ((error) 'pi-tool-failed) ((ok) 'pi-tool-done) (else 'pi-tool-meta)))])))

(def (tool-body-text (tool : chat-tool)) => :string
  (let ((output (strip-ansi tool.output))
        (bash? (equal? tool.name "bash")))
    (cond
     ((and (equal? tool.name "edit") (not (eq? tool.state 'error)))
      (let-values (((diff added removed) (edit-diff tool.args)))
        (if tool.folded?
          (let-values (((shown hidden) (text-preview diff preview-lines #f preview-bytes)))
            (more-note shown hidden #f))
          (text-capped diff expanded-bytes))))
     (tool.folded?
      (let-values (((shown hidden) (text-preview output (if bash? command-preview-lines preview-lines) bash? preview-bytes)))
        (more-note shown hidden bash?)))
     (else (text-capped output expanded-bytes)))))

;; SHOWN with a note that HIDDEN more lines come before (TAIL?) or after it.
(def (more-note (shown : :string) (hidden : :fixnum) (tail? : :boolean)) => :string
  (cond
   ((fx= hidden 0) shown)
   (tail? (string-append "… " (number->string hidden) " earlier lines\n" shown))
   (else (string-append shown "\n… " (number->string hidden) " more lines"))))

;; Spans marking an edit's removed and added lines in body TEXT.
(def (diff-spans (text : :string)) => :list
  (let lp ((lines (string-split text #\newline)) (position 1) (out []))
    (match lines
      ([] (reverse out))
      ([line . more]
       (let ((end (fx+ position (string-length line)))
             (face (cond ((string-prefix? "− " line) 'pi-diff-removed)
                         ((string-prefix? "+ " line) 'pi-diff-added)
                         (else #f))))
         (lp more (fx1+ end) (if (and face (fx< position end)) (cons (make-span position end face) out) out)))))))

(def (draw-tool! (tool : chat-tool)) => :void
  (let ((header (tool-header-text tool))
        (body (tool-body-text tool)))
    (unless (equal? header (text-string tool.header))
      (text-replace! tool.header 1 (fx1+ (text-size tool.header)) header))
    (set-highlights! tool.header 'pi (tool-header-spans tool header))
    (unless (equal? body (text-string tool.body))
      (text-replace! tool.body 1 (fx1+ (text-size tool.body)) body)
      (set-highlights! tool.body 'pi (if (equal? tool.name "edit") (diff-spans body) [])))
    (set-node-attribute! tool.element 'state tool.state)
    (set-node-attribute! tool.element 'folded tool.folded?)
    (let (children (if (string-empty? body) [tool.header-node] [tool.header-node tool.body-node]))
      (unless (fx= (length children) (node-child-count tool.element))
        (set-node-children! tool.element children)))))

;; A tool call ID of NAME with ARGS, not yet run.
(def (new-tool (id : :string) (name : :string) (args : :t) (keymaps : transcript-keymaps)) => chat-tool
  (let* ((header (new-text ""))
         (body (new-text ""))
         (header-node (new-node 'pi-header children: [(new-text-node header)] keymap: (transcript-keymaps-header keymaps)))
         (body-node (wrapped 'pi-tool-body body))
         (node (new-node 'pi-tool attributes: [(cons 'name name) (cons 'state 'called) (cons 'folded #t)]
                         children: [header-node]))
         (tool (chat-tool id: id name: name args: args element: node header-node: header-node header: header
                          body-node: body-node body: body state: 'called
                          started: #f duration: #f output: "" line: #f folded?: #t)))
    (draw-tool! tool)
    tool))

;; The file TOOL works on, or #f.
(def (chat-tool-path (tool : chat-tool)) => (Maybe :string)
  (tool-path tool.args))

;; TOOL's arguments are ARGS, as Pi gave them in full.
(def (set-tool-args! (tool : chat-tool) (args : :t)) => :void
  (when (hash-table? args)
    (set! tool.args args)
    (draw-tool! tool)))

;; TOOL started running at NOW, with ARGS.
(def (start-tool! (tool : chat-tool) (args : :t) (now : :real)) => :void
  (when (hash-table? args) (set! tool.args args))
  (set! tool.state 'running)
  (set! tool.started now)
  (draw-tool! tool))

;; TOOL's output so far is RESULT (a tool result: its content).
(def (set-tool-output! (tool : chat-tool) (result : :t)) => :void
  (set! tool.output (content-text (json-field result "content")))
  (draw-tool! tool))

;; TOOL ended with RESULT, failed when ERROR?, after DURATION ms (#f:
;; unknown).
(def (finish-tool! (tool : chat-tool) (result : :t) (error? : :boolean) (duration :? :real)) => :void
  (set! tool.output (content-text (json-field result "content")))
  (set! tool.state (if error? 'error 'ok))
  (set! tool.duration (or duration tool.duration))
  (let (line (json-field (json-field result "details") "firstChangedLine"))
    (when (and (fixnum? line) (fx> line 0)) (set! tool.line line)))
  (draw-tool! tool))

(def (toggle-tool! (tool : chat-tool)) => :void
  (set! tool.folded? (not tool.folded?))
  (draw-tool! tool))

;;; History

;; A message from Pi's get_messages, as a chat message, or #f for one the
;; transcript does not show; a tool result updates its tool instead
;; (TOOL-FOR, as in replace-assistant-content!, and TOOL-NAMED, id -> tool
;; or #f).
(def (history-message (record : :t) (keymaps : transcript-keymaps) (tool-for : :procedure) (tool-named : :procedure))
  => (Maybe chat-message)
  (let (role (json-field record "role"))
    (cond
     ((equal? role "user") (new-role-message 'user (content-text (json-field record "content")) keymaps))
     ((equal? role "assistant")
      (let (m (new-assistant-message keymaps))
        (replace-assistant-content! m (json-field record "content") keymaps tool-for)
        (set-message-error! m (assistant-error record))
        m))
     ((equal? role "toolResult")
      (let (tool (tool-named (or (json-field record "toolCallId") "")))
        (when tool (finish-tool! tool record (eq? (json-field record "isError") #t) #f))
        #f))
     ((and (equal? role "custom") (eq? (json-field record "display") #t))
      (new-role-message 'notice (content-text (json-field record "content")) keymaps))
     ((equal? role "bashExecution")
      (let* ((tool (tool-for (string-append "bash:" (number->string (or (json-field record "timestamp") 0))) "bash"
                             (hash ("command" (or (json-field record "command") "")))))
             (m (chat-message role: 'notice element: (message-node 'notice [(chat-tool-element tool)] keymaps)
                              parts: (make-hash-table))))
        (finish-tool! tool (hash ("content" [(hash ("type" "text") ("text" (or (json-field record "output") "")))]))
                      (not (memv (json-field record "exitCode") '(0 #f))) #f)
        m))
     ((equal? role "compactionSummary")
      (new-notice "The conversation was compacted to a summary." 'info keymaps))
     (else #f))))

;; Why an assistant message RECORD stopped early, or #f.
(def (assistant-error (record : :t)) => (Maybe :string)
  (let (reason (json-field record "stopReason"))
    (cond
     ((equal? reason "error") (string-append "Error: " (or (json-field record "errorMessage") "the reply failed")))
     ((equal? reason "aborted") "Stopped.")
     (else #f))))
