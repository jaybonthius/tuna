#lang :tuna/prelude
;;; The file picker: `completing-read` over the files of the folder typed
;;; so far, category `file`. The input is a file name ("~/notes/to"); the
;;; candidates are the entries of its folder ("~/notes/"), each written as
;;; that folder plus its name, folders ending in "/", so any matching style
;;; works on whole names. The listing comes from the file service and is
;;; read again only when the folder typed changes.
;;;
;;; Keys in the picker: DEL right after a "/" goes up a folder, deleting
;;; the last folder name ("~/a/b/" becomes "~/a/"); typing "/" after "~"
;;; anywhere jumps home ("~/a/~/" becomes "~/"). They are bound in a node
;;; the picker wraps around the prompt's answer, so they come before the
;;; global keys and after the completion list's.
(import :tuna/kernel
        :tuna/plugins/buffers/contract
        :tuna/plugins/minibuffer/contract
        :tuna/plugins/completion/contract
        :tuna/plugins/files/contract)
(export file-table
        file-annotations
        wrap-picker-answer!
        picker-delete-backward!
        picker-slash!
        human-size
        age-text)

;; Where the input's folder part points: (FOLDER-PART . FOLDER), the
;; folder part as typed (up to its last "/") and expanded from FROM.
(def (input-folder (input : :string) (from : :string)) => :pair
  (let (folder-part (file-name-directory input))
    (cons folder-part
          (file-name-as-directory
           (expand-file-name (if (string-empty? folder-part) "." folder-part) from)))))

;; A completion table of the files in the folder the input names,
;; relative names starting from FROM, a folder name ending in "/".
(def (file-table (from : :string)) => completion-table
  (let ((listed-folder #f) (listed []))
    (make-completion-table
     category: 'file
     items: (lambda ((input : :string))
              (let* ((where (input-folder input from))
                     (folder-part (car where))
                     (folder (cdr where)))
                (unless (equal? folder listed-folder)
                  (set! listed-folder folder)
                  (set! listed (with-catch (lambda (e) []) (lambda () (list-folder folder)))))
                (map (lambda ((entry : folder-entry))
                       (let* ((folder? (eq? (file-stat-kind (folder-entry-stat entry)) 'folder))
                              (suffix (if folder? "/" ""))
                              (text (string-append folder-part (folder-entry-name entry) suffix)))
                         (make-candidate text: text
                                         value: (string-append folder (folder-entry-name entry) suffix)
                                         key: text)))
                     (list-sort (lambda ((a : folder-entry) (b : folder-entry))
                                  (string<? (folder-entry-name a) (folder-entry-name b)))
                                listed)))))))

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

;; DEL: right after a "/" at the end of the input, the input becomes its
;; parent folder (abbreviated); elsewhere it deletes the character before
;; point.
(def (picker-delete-backward!) => :void
  (let ((input (picker-input))
        (p (point)))
    (cond
     ((and (fx= p (fx1+ (string-length input))) (string-suffix? "/" input) (fx> (string-length input) 1))
      (let* ((folder (expand-file-name input (buffer-default-directory (current-buffer))))
             (parent (file-name-directory (substring folder 0 (fx1- (string-length folder))))))
        (replace-input! (if (string-prefix? "~" input) (abbreviate-file-name parent) parent))))
     ((fx> p 1) (delete-region (fx1- p) p)))))

;; "/": insert it; when that makes the input end in "/~/" (or be "~/"
;; after more), the input becomes "~/".
(def (picker-slash!) => :void
  (insert "/")
  (let (input (picker-input))
    (when (and (string-suffix? "/~/" input) (fx= (point) (fx1+ (string-length input))))
      (replace-input! "~/"))))
