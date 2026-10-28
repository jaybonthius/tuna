#lang :tuna/prelude
;;; The file picker: `completing-read` over two sources, category `file`:
;;; "Recent files", then "This folder", the files of the folder typed so
;;; far. The input is a file name ("~/notes/to"); the folder's candidates
;;; are the entries of its folder ("~/notes/"), from the files contract's
;;; file-completion-table. Recent files are offered while the
;;; input's folder is the one the picker opened at, matched against the
;;; name typed after it: typing a folder means looking in it, so the
;;; listing is then that folder's alone.
;;;
;;; Keys in the picker: typing "/" after "~" anywhere jumps home
;;; ("~/a/~/" becomes "~/"), as Emacs's substitute-in-file-name reads
;;; such a name; DEL is the ordinary editing key, as in Emacs's file
;;; prompt. The key is bound in a node
;;; the picker wraps around the prompt's answer, so they come before the
;;; global keys and after the completion list's.
(import :tuna/kernel
        :tuna/plugins/buffers/contract
        :tuna/plugins/minibuffer/contract
        :tuna/plugins/completion/contract
        :tuna/plugins/files/contract)
(export recent-file-table
        file-annotations
        wrap-picker-answer!
        picker-slash!
        human-size
        age-text)

;; FILES, true names most recent first, as a source titled TITLE, in that
;; order. With STARTING, the folder the picker opened at as typed, they are
;; offered only while the input's folder part is that or empty, and matched
;; against the name typed after it; otherwise against the whole input.
(def (recent-file-table (files : :list) (title :? :string) (starting :? :string)) => completion-table
  (let (candidates (map (lambda ((name : :string))
                          (let (text (abbreviate-file-name name))
                            (make-candidate text: text value: name key: (cons 'recent text))))
                        files))
    (make-completion-table
     category: 'file
     title: title
     sort: values
     items: (if starting
              (lambda ((input : :string))
                (if (member (file-name-directory input) ["" starting]) candidates []))
              candidates)
     query: (and starting file-name-nondirectory))))

;; SIZE bytes as "512", "1.2K", "34M".
(def (human-size (size : :integer)) => :string
  (let lp ((value (exact->inexact size)) (units '("K" "M" "G" "T")) (unit ""))
    (if (or (< value 1024.) (null? units))
      (if (string-empty? unit)
        (number->string size)
        (let (rounded (/ (round (* value 10.)) 10.))
          (string-append (if (< rounded 10.)
                           (number->string rounded)
                           (number->string (inexact->exact (round rounded))))
                         unit)))
      (lp (/ value 1024.) (cdr units) (car units)))))

;; How long ago NANOSECONDS (since 1970) was, from NOW (seconds): "now",
;; "5 min ago", "3 h ago", "12 d ago", "2 y ago".
(def (age-text (nanoseconds : :integer) (now : :real)) => :string
  (let (seconds (max 0 (- now (/ nanoseconds 1e9))))
    (let-values (((amount unit)
                  (cond
                   ((< seconds 60) (values #f "now"))
                   ((< seconds 3600) (values (floor (/ seconds 60)) "min"))
                   ((< seconds 86400) (values (floor (/ seconds 3600)) "h"))
                   ((< seconds (* 365 86400)) (values (floor (/ seconds 86400)) "d"))
                   (else (values (floor (/ seconds (* 365 86400))) "y")))))
      (if amount
        (string-append (number->string (inexact->exact amount)) " " unit " ago")
        unit))))

;; The file annotator: size (folders have none), how long ago it changed,
;; and "open" when a buffer visits it.
(def (file-annotations (c : candidate)) => (Maybe :list)
  (let* ((path (candidate-value c))
         (stat (and (string? path) (stat-file path))))
    (and stat
         (let* ((truename (true-name path))
                (open? (ormap (lambda ((b : buffer))
                                (let (v (buffer-visit b))
                                  (and v (equal? (visit-true-name v) truename))))
                              (file-buffers))))
           [(make-annotation-field (if (eq? (file-stat-kind stat) 'folder) "" (human-size (file-stat-size stat))) 'file-size)
            (make-annotation-field (age-text (file-stat-modified stat) (time->seconds (current-time))) 'file-modified)
            (make-annotation-field (if open? "open" "") 'file-open)]))))

;; Wrap prompt P's answer in a picker node with KEYMAP, so the picker's
;; keys apply while it is answered.
(def (wrap-picker-answer! (p : Prompt) (keymap : entry-table)) => :void
  (let* ((root (buffer-root (prompt-buffer p)))
         (answer (prompt-answer-node p))
         (children (node-children root)))
    (set-node-children! root (remq answer children))
    (let (wrapper (new-node 'file-picker-input children: [answer] keymap: keymap))
      (set-node-children! root (map (lambda (n) (if (eq? n answer) wrapper n)) children)))))

;; The picker's input: the current text, which is the answer's.
(def (picker-input) => :string
  (text-string (current-text)))

(def (replace-input! (input : :string)) => :void
  (let (t (current-text))
    (text-replace! t 1 (fx1+ (text-size t)) input)
    (goto-char (fx1+ (string-length input)))))

;; "/": insert it; when that makes the input end in "/~/" (or be "~/"
;; after more), the input becomes "~/".
(def (picker-slash!) => :void
  (insert "/")
  (let (input (picker-input))
    (when (and (string-suffix? "/~/" input) (fx= (point) (fx1+ (string-length input))))
      (replace-input! "~/"))))
