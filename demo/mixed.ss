;;; The mixed demo plugin, for development only (`tuna --config
;;; demo/init.ss`): C-c M shows *mixed*, a long buffer that is not one
;;; text: 2,000 sections, each a heading and then a wrapped paragraph, a
;;; code block, a card or a picture. Paragraphs and code blocks hold text
;;; nodes you can edit, and open into their lines; headings, cards and
;;; pictures are one item each, of different heights. It scrolls by the
;;; same machinery as *long* (C-c g) and *rows* (C-c G).
prelude: :gerbil/core

(import :tuna/kernel
        :tuna/plugins/commands/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract
        :tuna/plugins/stylesheets/contract)
(export mixed-demo)

(def mixed-buffer-name "*mixed*")
(def mixed-section-count 2000)

(def words
  (list->vector
   (string-split "tuna buffer node view layout scroll anchor height measure browser server morph frame window emacs redisplay point mark region column tree text proportional monospace wrapped paragraph item spacer placement" #\space)))

;; The same content every time, from a fixed linear congruential sequence.
(def (next-seed (seed : :fixnum)) => :fixnum
  (modulo (+ (* seed 1103515245) 12345) 2147483648))

;; COUNT words starting from SEED, and the seed after them (two values;
;; Gerbil types no multiple-value returns, so these helpers have none).
(def (some-words (count : :fixnum) (seed : :fixnum))
  (let lp ((i 0) (s seed) (out []))
    (if (fx< i count)
      (let (s (next-seed s))
        (lp (fx1+ i) s (cons (vector-ref words (modulo (quotient s 65536) (vector-length words))) out)))
      (values (string-join (reverse out) " ") s))))

;; A random number in 0..BOUND-1 from SEED, and the next seed.
(def (pick (bound : :fixnum) (seed : :fixnum))
  (let (s (next-seed seed))
    (values (modulo (quotient s 65536) bound) s)))

;; A paragraph: one text node, a single line long enough to wrap.
(def (paragraph (seed : :fixnum))
  (let*-values (((count s) (pick 80 seed))
                ((text s) (some-words (fx+ 10 count) s)))
    (values (new-node 'mixed-paragraph children: [(new-text-node (new-text text))]) s)))

;; A code block: one text node of 2 to 14 lines.
(def (code-block (seed : :fixnum))
  (let*-values (((lines s) (pick 13 seed)))
    (let lp ((i 0) (s s) (out []))
      (if (fx<= i (fx1+ lines))
        (let*-values (((indent s) (pick 4 s))
                      ((count s) (pick 7 s))
                      ((line s) (some-words (fx1+ count) s)))
          (lp (fx1+ i) s (cons (string-append (make-string (fx* 2 indent) #\space) "(" line ")") out)))
        (values (new-node 'mixed-code children: [(new-text-node (new-text (string-join (reverse out) "\n")))])
                s)))))

;; A card: a title, a body of different lengths and a few tags; one item.
(def (card (number : :fixnum) (seed : :fixnum))
  (let*-values (((title s) (some-words 3 seed))
                ((length s) (pick 60 s))
                ((body s) (some-words (fx+ 5 length) s))
                ((tags s) (some-words 3 s)))
    (values (new-node 'mixed-card attributes: [(cons 'title (string-append "Card " (number->string number) ": " title))
                                               (cons 'body body)
                                               (cons 'tags tags)])
            s)))

;; A picture: a captioned box 60 to 360 px tall; one item.
(def (picture (number : :fixnum) (seed : :fixnum))
  (let*-values (((height s) (pick 301 seed)))
    (values (new-node 'mixed-picture attributes: [(cons 'height (fx+ 60 height))
                                                  (cons 'caption (string-append "Picture " (number->string number)))])
            s)))

(def (mixed-buffer) => buffer
  (new-buffer mixed-buffer-name
              (new-node 'mixed
                        children:
                        (let lp ((number 1) (seed 11) (out []))
                          (if (fx> number mixed-section-count)
                            (reverse out)
                            (let*-values (((kind s) (pick 4 seed))
                                          ((title s) (some-words 4 s))
                                          ((body s) (case kind
                                                      ((0) (paragraph s))
                                                      ((1) (code-block s))
                                                      ((2) (card number s))
                                                      (else (picture number s)))))
                              (lp (fx1+ number) s
                                  (cons* body
                                         (new-node 'mixed-heading
                                                   attributes: [(cons 'label (string-append (number->string number) ". " title))])
                                         out))))))))

(defplugin (mixed-demo ctx)
  "C-c M: *mixed*, a long buffer of headings, paragraphs, code, cards and pictures, for trying scrolling."
  requires: [commands-service input-service buffers-service layout-service]
  (add-stylesheet 'rules "mixed.css")
  (context-define-node-kind! ctx 'mixed doc: "Sections, one under another." items: 'children)
  (context-define-node-kind! ctx 'mixed-heading doc: "A section's heading." items: 'whole
                             project: (lambda (n) (node-attribute n 'label)))
  (context-define-node-kind! ctx 'mixed-paragraph doc: "A wrapped paragraph of text." items: 'children)
  (context-define-node-kind! ctx 'mixed-code doc: "A block of code text." items: 'children)
  (context-define-node-kind! ctx 'mixed-card doc: "A card: a title, a body and tags." items: 'whole
                             project: (lambda (n) (node-attribute n 'title)))
  (context-define-node-kind! ctx 'mixed-picture doc: "A captioned picture." items: 'whole
                             project: (lambda (n) (node-attribute n 'caption)))
  (context-define-node-renderer! ctx 'mixed (lambda (n children) `(div (@ (class "mixed")) ,@children)))
  (context-define-node-renderer! ctx 'mixed-heading
                                 (lambda (n children) `(h2 (@ (class "mixed-heading")) ,(node-attribute n 'label))))
  (context-define-node-renderer! ctx 'mixed-paragraph
                                 (lambda (n children) `(div (@ (class "mixed-paragraph")) ,@children)))
  (context-define-node-renderer! ctx 'mixed-code
                                 (lambda (n children) `(div (@ (class "mixed-code")) ,@children)))
  (context-define-node-renderer! ctx 'mixed-card
                                 (lambda (n children)
                                   `(article (@ (class "mixed-card"))
                                             (h3 ,(node-attribute n 'title))
                                             (p ,(node-attribute n 'body))
                                             (p (@ (class "mixed-tags")) ,(node-attribute n 'tags)))))
  ;; The picture's height is the content's size, not a style.
  (context-define-node-renderer! ctx 'mixed-picture
                                 (lambda (n children)
                                   `(figure (@ (class "mixed-picture")
                                               (style ,(string-append "--mixed-picture-block-size: "
                                                                      (number->string (node-attribute n 'height)) "px")))
                                            (figcaption ,(node-attribute n 'caption)))))
  (define-command ctx (mixed-buffer) "Show *mixed*, a long buffer of mixed sections, making it the first time."
    (let (b (or (get-buffer mixed-buffer-name)
                (let (b (mixed-buffer))
                  (context-add-buffer! ctx b)
                  b)))
      (set-view-buffer (selected-view) b)))
  (keymap-set ctx "C-c M" 'mixed-buffer))
