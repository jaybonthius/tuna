;;; The text of a chat's tool blocks: escape sequences stripped, the key
;;; argument of a header, previews from the start or (a command's) the end,
;;; an edit's diff, durations.
(import :std/test
        :tuna/plugins/pi/jsonl
        :tuna/plugins/pi/tool-text)
(export tool-text-test)

(def (preview (text : :string) (lines : :fixnum) (tail? : :boolean) (bytes : :fixnum := 1000)) => :list
  (let-values (((shown hidden) (text-preview text lines tail? bytes)))
    [shown hidden]))

(def tool-text-test
  (test-suite "tuna/plugins/pi: tool text"
    (test-case "escape sequences and control characters go; CR LF becomes LF"
      (check (strip-ansi "\x1b;[1;31mred\x1b;[0m and \x1b;]8;;http://x\x7;link\x1b;]8;;\x1b;\\ done\r\nnext\x1;")
             => "red and link done\nnext"))

    (test-case "a header shows a command, a path, or the arguments as JSON on one line"
      (check (tool-key-argument "bash" (parse-json-line "{\"command\":\"make\\n  test\"}")) => "make test")
      (check (tool-key-argument "read" (parse-json-line "{\"path\":\"a/b.ss\",\"offset\":3}")) => "a/b.ss")
      (check (tool-key-argument "edit" (parse-json-line "{\"file_path\":\"c.ss\"}")) => "c.ss")
      (check (tool-key-argument "grep" (parse-json-line "{\"pattern\":\"x\"}")) => "{\"pattern\":\"x\"}")
      (check (tool-key-argument "ls" (parse-json-line "{}")) => ""))

    (test-case "a preview keeps the first lines, or a command's last, and says how many it left out"
      (check (preview "1\n2\n3\n4\n" 2 #f) => ["1\n2" 2])
      (check (preview "1\n2\n3\n4" 2 #t) => ["3\n4" 2])
      (check (preview "1\n2" 5 #f) => ["1\n2" 0])
      (check (car (preview (make-string 50 #\a) 3 #f 10)) => (string-append (make-string 10 #\a) "\n… (40 more characters)")))

    (test-case "an edit is a diff of its old and new lines, with counts"
      (let-values (((diff added removed)
                    (edit-diff (parse-json-line "{\"path\":\"x\",\"edits\":[{\"oldText\":\"a\\nb\",\"newText\":\"c\"},{\"oldText\":\"d\",\"newText\":\"e\\nf\"}]}"))))
        (check diff => "− a\n− b\n+ c\n\n− d\n+ e\n+ f")
        (check [added removed] => [3 3]))
      (let-values (((diff added removed) (edit-diff (parse-json-line "{\"oldText\":\"a\",\"newText\":\"b\"}"))))
        (check diff => "− a\n+ b")))

    (test-case "content text joins text blocks; durations read as people say them"
      (check (content-text (parse-json-line "{\"c\":[{\"type\":\"text\",\"text\":\"a\"},{\"type\":\"image\"},{\"type\":\"text\",\"text\":\"b\"}]}"))
             => "")
      (check (content-text (json-field (parse-json-line "{\"c\":[{\"type\":\"text\",\"text\":\"a\"},{\"type\":\"image\"},{\"type\":\"text\",\"text\":\"b\"}]}") "c"))
             => "a\n[image]\nb")
      (check (duration-text 120) => "0.1 s")
      (check (duration-text 41000) => "41 s")
      (check (duration-text 125000) => "2 min 5 s"))))
