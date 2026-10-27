;;; A stand-in page service for the terminal plugin's tests: it keeps the
;;; page addresses the plugin adds, so a test posts to them as the page
;;; script would, and the one-time instructions it sends.
(import :tuna/kernel
        :tuna/plugins/clients/contract
        :tuna/plugins/web/contract)
(export recording-page
        post-to-page-address
        page-instructions
        forget-page-instructions!)

(defclass page-record (addresses instructions) final: #t)
(defmethod {add-script! page-record} (lambda (self ctx path) (void)))
(defmethod {add-address! page-record}
  (lambda (self ctx name handler) (hash-put! (page-record-addresses self) name handler)))
(defmethod {instruct! page-record}
  (lambda (self c action argument)
    (set! (page-record-instructions self) (cons [action argument] (page-record-instructions self)))))

(def page (make-page-record addresses: (make-hash-table) instructions: []))

(defplugin (recording-page ctx)
  "Keeps the page addresses and instructions plugins ask for."
  provides: [page-service]
  (context-provide! ctx page-service (Page page)))

;; Post JSON, a string, to the address NAME from client C, as a page
;; script does: on the caller's thread, not the editor's.
(def (post-to-page-address (name : :string) (json : :string) client: (c (make-client "test"))) => :void
  ((hash-ref (page-record-addresses page) name) c (string->utf8 json)))

;; The instructions sent, oldest first: (ACTION ARGUMENT).
(def (page-instructions) => :list
  (reverse (page-record-instructions page)))

(def (forget-page-instructions!) => :void
  (set! (page-record-instructions page) []))
