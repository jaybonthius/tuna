(import (tuna) (test) (test-user) (test-runner) (options) (buffers) (document) (views) (layout) (files) (projects)
        (minibuffer) (file-picker) (jump-history) (kill-ring) (ask) (chat) (chat-test fake-talks) (chat-test fake-agents) (chat-test))

(define home (getenv "HOME"))

(define (at path) (string-append home "/" path))

(define (write-file! path text)
  (call-with-output-file (at path) (lambda (p) (put-string p text)) 'replace))

(for-each (lambda (f) (mkdir (at f))) '("proj" "proj/lib" "proj/sub" "other"))

(write-file! "proj/lib/a.txt" "one\ntwo\nthree\nfour\n")

(write-file! "proj/.project" "")

(write-file! "proj/sub/.project" "")

(options:set! projects:extra-root-markers '(".project"))

(options:set! chat:default-source 'chat-test/fake-agents:echo)

(define e (chat-test/fake-talks:start 'echo (at "proj/")))

(define b (chat:buffer e))

(define (where) (views:describe-at-point (chat-test:view)))

(test "in a chat the conversation counts your messages, the prompt has its own lines, and the rest shows no position"
  (chat:show! e)
  (chat-test/fake-talks:reply! e "Hello")
  (chat-test/fake-talks:add! e 'user "First")
  (chat-test/fake-talks:reply! e "Answer one")
  (chat-test/fake-talks:add! e 'user "Second")
  (chat-test/fake-talks:reply! e "Answer two")
  (test-user:settle)
  (test-user:type! "ab")
  (test-user:press! "S-RET")
  (test-user:type! "cd")
  (check-equal? "L2" (where))
  (check-equal? '(#f "message 1 of 2" "message 1 of 2" "message 2 of 2" "message 2 of 2")
    (map (lambda (text) (chat-test:at! b text) (where)) '("Hello" "First" "Answer one" "Second" "Answer two"))))

(test "n and p in the conversation go from message to message of yours"
  (chat-test:at! b "Hello")
  (check-equal? '("message 1 of 2" "message 2 of 2" "message 1 of 2")
    (map (lambda (key) (test-user:press! key) (where)) '("n" "n" "p")))
  (check-equal? '("no earlier message") (chat-test:press! "p"))
  (test-user:press! "n")
  (check-equal? '("no later message") (chat-test:press! "n")))

(test "w copies the message at point, as the source's item text"
  (chat-test:at! b "Answer one")
  (test-user:press! "w")
  (check-equal? "Answer one" (kill-ring:text (kill-ring:current))))

(test "a chat's buffer gives files:directory the chat's folder, so C-x C-f there starts there"
  (check-equal? (at "proj/") (files:directory b))
  (check-equal? (at "proj/") (chat:folder-for b))
  (chat:show! e)
  (test-user:press! "C-x C-f")
  (check-equal? "~/proj/" (minibuffer:input (minibuffer:current-prompt)))
  (check-equal? '(quit) (chat-test:press! "C-g")))

(test "a chat started in a folder written with .. gives its buffer the folder without it, and two chats of one folder name differ"
  (let* ([up (chat-test/fake-talks:start 'echo (at "proj/sub/.."))] [ub (chat:buffer up)])
    (check-equal? (list (at "proj/") (at "proj") (at "proj/")) (list (files:directory ub) (chat:folder-for ub) (projects:root (projects:find (files:directory ub)))))
    (check-equal? "*echo: proj*<2>" (buffers:name ub))
    (chat-test/fake-talks:end! up)
    (test-user:settle)
    (check-equal? #f (buffers:live? ub))))

(define file-buffer (files:visit (at "proj/lib/a.txt")))

(test "C-c a t shows the chat used last in the buffer's project, and removes the view showing it"
  (layout:switch-to-buffer file-buffer)
  (test-user:press! "C-c a t")
  (check (eq? b (views:buffer (chat-test:view))))
  (test-user:press! "C-c a t")
  (check (eq? file-buffer (views:buffer (chat-test:view)))))

(test "hiding a chat in a view that cannot go shows what the view showed before its chats, not another chat"
  (let ([second (chat-test/fake-talks:start 'echo (at "proj/"))])
    (layout:switch-to-buffer (chat:buffer second))
    (layout:switch-to-buffer b)
    (test-user:press! "C-c a t")
    (check (eq? file-buffer (views:buffer (chat-test:view))))
    (chat-test/fake-talks:end! second)
    (test-user:settle)))

(test "a chat started in a folder inside the project is in the project's group, before chats elsewhere"
  (let ([inside (chat-test/fake-talks:start 'echo (at "proj/lib"))] [elsewhere (chat-test/fake-talks:start 'echo home)])
    (test-user:settle)
    (check-equal? (list (at "proj/") (at "proj/lib") home) (map chat-test/fake-talks:talk-directory (chat:chats-for file-buffer)))
    (chat-test/fake-talks:end! inside)
    (chat-test/fake-talks:end! elsewhere)
    (test-user:settle)))

(test "C-c a r adds a reference the agent reads for an unmodified file buffer, the text in a fence for any other, and shows the chat"
  (chat:set-prompt! e "")
  (layout:switch-to-buffer file-buffer)
  (views:set-point! (chat-test:view) 5)
  (views:set-mark! (chat-test:view) 15)
  (test-user:press! "C-c a r")
  (check (eq? b (views:buffer (chat-test:view))))
  (check-equal? "lib/a.txt:2-3" (chat-test:prompt-text e))
  (layout:switch-to-buffer file-buffer)
  (views:set-point! (chat-test:view) 1)
  (test-user:type! "x")
  (views:set-point! (chat-test:view) 1)
  (views:set-mark! (chat-test:view) 6)
  (test-user:press! "C-c a r")
  (check-equal? "lib/a.txt:2-3\n```a.txt lines 1-1\nxone\n```" (chat-test:prompt-text e)))

(test "an atom in the region goes as its text: a raw byte as U+FFFD"
  (buffers:splice! file-buffer 2 2 (document:from-utf8 #vu8(#xFF)))
  (check-equal? "```a.txt lines 1-1\nx\xFFFD;o\n```" (chat:region-text e file-buffer 1 4)))

(test "chat:region-text and chat:folder-for check their arguments"
  (check-equal? "not a start and an end in the buffer" (chat-test:raised (lambda () (chat:region-text e file-buffer 5 1))))
  (check-equal? "not a buffer" (chat-test:raised (lambda () (chat:folder-for 'b)))))

(test "C-c a r raises with no region, and with no chat in the buffer's project asks to start one, naming the folder with ~"
  (layout:switch-to-buffer file-buffer)
  (views:set-mark! (chat-test:view) #f)
  (check-equal? '("the region is empty") (chat-test:press! "C-c a r"))
  (write-file! "other/c.txt" "c\n")
  (let ([asked '()] [c-buffer (files:visit (at "other/c.txt"))])
    (options:set! ask:y-or-n-reader (lambda (question) (set! asked (cons question asked)) #f))
    (layout:switch-to-buffer c-buffer)
    (views:set-point! (chat-test:view) 1)
    (views:set-mark! (chat-test:view) 2)
    (let ([before (length ((chat-test/fake-talks:live 'echo)))])
      (test-user:press! "C-c a r")
      (check-equal? '("Start a Echo chat in ~/other/? ") asked)
      (check-equal? before (length ((chat-test/fake-talks:live 'echo)))))
    (options:set! ask:y-or-n-reader (lambda (question) #t))
    (test-user:press! "C-c a r")
    (let ([started (chat-test:current)])
      (check-equal? (at "other/") (chat-test/fake-talks:talk-directory started))
      (check-equal? "c.txt:1" (chat-test:prompt-text started)))
    (options:unset! ask:y-or-n-reader)))

(test "RET on a path:line in the conversation opens the file at that line, relative to the chat's folder, and M-, returns"
  (chat:show! e)
  (chat-test/fake-talks:reply! e "See lib/a.txt:3 and lib/a.txt:99.")
  (test-user:settle)
  (chat-test:at! b "lib/a.txt:3")
  (let ([link (views:point (chat-test:view))])
    (test-user:press! "RET")
    (let ([v (chat-test:view)])
      (check (eq? file-buffer (views:buffer v)))
      (check-equal? 3 (document:line (buffers:document file-buffer) (views:point v))))
    (test-user:press! "M-,")
    (check (eq? b (views:buffer (chat-test:view))))
    (check-equal? link (views:point (chat-test:view)))))

(test "a line past the file's last goes to its end, and RET with no file at point raises"
  (chat-test:at! b "lib/a.txt:99")
  (test-user:press! "RET")
  (check-equal? (- (document:length (buffers:document file-buffer)) 1) (views:point (chat-test:view)))
  (chat:show! e)
  (chat-test:at! b "Hello")
  (check-equal? '("no file is at point") (chat-test:press! "RET")))

(test "chat:files-edited! reverts an unmodified buffer visiting the file, and leaves a modified one with a notice naming the source"
  (let ([fresh (files:visit (at "proj/lib/b.txt"))])
    (write-file! "proj/lib/b.txt" "before\n")
    (files:revert-from-file fresh)
    (files:not-modified fresh)
    (write-file! "proj/lib/b.txt" "edited by the agent\n")
    (chat:files-edited! e (list (at "proj/lib/b.txt")))
    (test-runner:wait-until (lambda () (string=? "edited by the agent\n" (chat-test:text fresh))))
    (check-equal? #t (buffers:modified? file-buffer))
    (write-file! "proj/lib/a.txt" "edited again\n")
    (chat:files-edited! e (list (at "proj/lib/a.txt")))
    (test-user:settle)
    (check (not (string=? "edited again\n" (chat-test:text file-buffer))))
    (check-equal? "a.txt has unsaved changes, so Echo's edit of its file is not shown in it"
      (test-user:element-text (car (last-pair (test-user:elements (test-user:screen) "chat-notice")))))))
