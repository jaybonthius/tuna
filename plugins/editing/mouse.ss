#lang :tuna/prelude
;;; Clicking and dragging in text (Emacs's mouse.el), for the editing
;;; plugin, which defines these commands. Each command selects
;;; the view the pointer event names, as a click in a window does in Emacs,
;;; and works at the gap between characters the event names (the layout
;;; contract's `posn-point`), in the text node holding it
;;; (`posn-text-node`). A press or click in another text node of the
;;; view's buffer first moves the view's focus there (the buffers
;;; contract's `set-view-focus!`), which deactivates the region:
;;;
;;; - a press (`down-mouse-1`, `mouse-drag-region`) moves point there and
;;;   deactivates the region; the press is remembered, for its client,
;;;   until the release;
;;; - each movement while the button is held (`mouse-movement`,
;;;   `mouse-drag-movement`) moves point there, and once it is not where the
;;;   press was, puts the mark at the press and activates the region;
;;; - the release after a drag (`drag-mouse-1`, `mouse-set-region`) sets
;;;   the region from the press to there, or, when that is empty, is a
;;;   plain click;
;;; - a click (`mouse-1`, `mouse-set-point`) moves point there and
;;;   deactivates the region; a double click selects the word there and a
;;;   triple click the line, with its newline (Emacs's `mouse-set-point`
;;;   promoting a multiple click to `mouse-set-region`, and
;;;   `mouse-start-end`);
;;; - a press with shift (`S-down-mouse-1`,
;;;   `mouse-drag-region-shift-adjust`) keeps the mark where it is when the
;;;   region is active, otherwise puts it at point, and moves point there;
;;;   its release (`S-mouse-1`, `S-drag-mouse-1`) is `mouse-set-region`,
;;;   so shift-click extends the selection, as with Emacs's
;;;   `mouse-shift-adjust-mode` on.
;;;
;;; A press on a double or triple click selects by words or lines from the
;;; start, and dragging it extends by words or lines. A region the mouse
;;; made is temporary (the editing contract's `set-temporary-region!`): the
;;; next unshifted motion command ends it. A region stays in one text
;;; node: a drag ignores positions outside the node pressed in, and a
;;; shift-click in another node only moves point there. A click below the
;;; view's text goes to the end of its focused text; a click on a line
;;; that is gone says so; a drag released outside the text ends where the
;;; last movement put point.
;;; A node's own click binding, such as a button's or a completion row's,
;;; shadows these. Views whose buffer other-view skips (the bar's) refuse,
;;; as `mouse-select-view` does.
(import (only-in :gerbil/runtime/hash HashTable)
        :tuna/kernel
        (only-in :tuna/plugins/clients/contract current-client)
        :tuna/plugins/commands/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/editing/contract
        :tuna/plugins/layout/contract)
(export define-mouse-commands!)

;; A press being dragged, from the press to its release: the view and
;; text node pressed in (IN-VIEW, IN-NODE; a field named view would
;; shadow the type), the position pressed, ANCHOR, valid at that text's
;; character revision REVISION, and what the drag selects by (Emacs's
;; `mouse-start-end` MODE): 0 characters, 1 words, 2 lines.
(defstruct press ((in-view  : view)
                  (in-node  : node)
                  (anchor   : :fixnum)
                  (revision : :fixnum)
                  (mode     : :fixnum))
  final: #t)

;; Each client's press being dragged (#f for events without a client).
(defclass mouse-state ((presses : HashTable))
  final: #t)

;;; Words and lines

(def (char-at (t : text) (position : :fixnum)) => (Maybe :char)
  (and (fx<= 1 position (text-size t))
       (string-ref (text-substring t position (fx1+ position)) 0)))

;; C's class in Emacs's standard syntax table: whitespace, a word
;; constituent (letters, digits, $, % and every non-ASCII character), a
;; symbol constituent, or something else (punctuation, brackets, quotes).
(def (char-class (c : :char)) => :symbol
  (cond
   ((memv c '(#\space #\tab #\newline #\return #\page)) 'space)
   ((or (char-alphabetic? c) (char-numeric? c) (memv c '(#\$ #\%)) (fx>= (char->integer c) 128)) 'word)
   ((memv c '(#\_ #\- #\+ #\* #\/ #\& #\| #\< #\> #\=)) 'symbol)
   (else 'other)))

;; Whether C continues a run started by FIRST, as Emacs's
;; `mouse-skip-word` skips: a word's characters, a symbol's word and
;; symbol characters, whitespace, or else the same character again.
(def (same-run? (first : :char) (c : :char)) => :boolean
  (case (char-class first)
    ((word) (eq? (char-class c) 'word))
    ((symbol) (and (memq (char-class c) '(word symbol)) #t))
    ((space) (eq? (char-class c) 'space))
    (else (char=? c first))))

;; The start of the run of characters holding the one after POSITION.
(def (run-start (t : text) (position : :fixnum)) => :fixnum
  (let (first (char-at t position))
    (if first
      (let lp ((p position))
        (let (c (char-at t (fx1- p)))
          (if (and c (same-run? first c)) (lp (fx1- p)) p)))
      position)))

;; The end of the run of characters holding the one after POSITION.
(def (run-end (t : text) (position : :fixnum)) => :fixnum
  (let (first (char-at t position))
    (if first
      (let lp ((p position))
        (let (c (char-at t p))
          (if (and c (same-run? first c)) (lp (fx1+ p)) p)))
      position)))

;; The region selecting from A to B by MODE (Emacs's `mouse-start-end`),
;; as (start . end): 0, the characters between them; 1, the words, or
;; runs of whitespace or of one other character, at both ends; 2, their
;; whole lines, newlines included. Emacs's double click on a bracket or
;; quote, selecting the expression it delimits, is not done.
(def (mouse-start-end (t : text) (a : :fixnum) (b : :fixnum) (mode : :fixnum)) => :pair
  (let ((start (fxmin a b))
        (end (fxmax a b)))
    (case mode
      ((1) (cons (run-start t start) (run-end t end)))
      ((2) (let (last (text-line-at t end))
             (cons (text-line-start t (text-line-at t start))
                   (if (fx< last (text-line-count t))
                     (text-line-start t (fx1+ last))
                     (fx1+ (text-size t))))))
      (else (cons start end)))))

;; What a press on the CLICKSth click in a row selects by (Emacs's click
;; count, less one, modulo 3).
(def (click-mode (clicks : :fixnum)) => :fixnum
  (fxmodulo (fx1- clicks) 3))

;;; The commands

;; The posn of the pointer event being handled, or #f, with a message,
;; when the command did not run from one.
(def (pointer-posn (command : :string)) => (Maybe posn)
  (or (event-start (last-command-event))
      (begin (message (string-append command " runs only from the mouse")) #f)))

(def (event-clicks) => :fixnum
  (using (event (last-command-event) : pointer-event)
    event.clicks))

;; The view P names, selected, or #f when it is gone, which is reported,
;; or skipped by other-view.
(def (select-posn-view (p : posn)) => (Maybe view)
  (let (v (posn-view p))
    (cond
     ((not v) (report-stale-click p) #f)
     ((view-skipped? v) #f)
     (else (select-view v) v))))

;; The text node P names a position in and that position (posn-text-node,
;; posn-point), as (node . position), or #f.
(def (clicked-text (p : posn)) => (Maybe :pair)
  (let ((n (posn-text-node p))
        (position (posn-point p)))
    (and n position (cons n position))))

;; The position P names in V's focused text node; #f when P names none,
;; or one in another text node.
(def (text-position (v : view) (p : posn)) => (Maybe :fixnum)
  (let (place (clicked-text p))
    (and place (eq? (car place) (view-node v)) (cdr place))))

;; The position P names in a text node of the buffer V shows, or #f; when
;; that is not V's focused node, V's focus moves there first, with point
;; at the position and no mark (set-view-focus!).
(def (focus-position! (v : view) (p : posn)) => (Maybe :fixnum)
  (let (place (clicked-text p))
    (and place
         (begin
           (unless (eq? (car place) (view-node v))
             (set-view-focus! v (car place) (cdr place)))
           (cdr place)))))

;; Report a click on a line that is gone, when P names one.
(def (report-gone-line (p : posn)) => :void
  (when (and (posn-line p) (not (posn-point p)))
    (report-stale-click p what: "line")))

;; Set the selected view V's region from A to B by MODE (mouse-start-end),
;; with point at B's end; an empty one deactivates the region instead,
;; leaving point there (Emacs's `mouse-set-region`, and
;; `mouse--drag-set-mark-and-point` while dragging, which keeps an empty
;; region active once it was).
(def (select-between! (v : view) (a : :fixnum) (b : :fixnum) (mode : :fixnum) dragging?: (dragging? : :boolean := #f))
  => :void
  (let* ((range (mouse-start-end (text-node-content (:- (view-node v) node)) a b mode))
         (mark (if (fx< b a) (cdr range) (car range)))
         (point (if (fx< b a) (car range) (cdr range))))
    (set-view-point! v point)
    (cond
     ((not (fx= mark point)) (set-temporary-region! mark))
     ((and dragging? (view-mark-active? v)) (set-temporary-region! mark))
     (else (deactivate-mark!)))))

;; Where the press PR was, now, in V's focused text node, or #f when V
;; no longer shows the text pressed in.
(def (pressed-position (pr : press) (v : view)) => (Maybe :fixnum)
  (and (eq? (press-in-view pr) v) (eq? (view-node v) (press-in-node pr))
       (let (t (text-node-content (press-in-node pr)))
         (fxmax 1 (fxmin (relocate-position t (press-anchor pr) (press-revision pr)) (fx1+ (text-size t)))))))

;; Emacs `mouse-drag-region` (and, with SHIFT?, `mouse-drag-region-shift-adjust`).
(def (drag-region! (self : mouse-state) (shift? : :boolean)) => :void
  (let (p (pointer-posn (if shift? "mouse-drag-region-shift-adjust" "mouse-drag-region")))
    (hash-remove! self.presses (current-client))
    (let (v (and p (select-posn-view p)))
      (when v
        (let (position (focus-position! v p))
          (if position
            (let* ((n (:- (view-node v) node))
                   (t (text-node-content n))
                   (mode (if shift? 0 (click-mode (event-clicks))))
                   (anchor (if (and shift? (view-mark-active? v)) (:- (view-mark v) :fixnum) (view-point v))))
              (cond
               (shift?
                (hash-put! self.presses (current-client) (press v n anchor (text-chars-revision t) 0))
                (select-between! v anchor position 0))
               (else
                (hash-put! self.presses (current-client) (press v n position (text-chars-revision t) mode))
                (deactivate-mark!)
                (select-between! v position position mode))))
            (report-gone-line p)))))))

;; Where the held button moved: point there, the region from the press;
;; a position outside the text node pressed in is ignored.
(def (drag-movement! (self : mouse-state)) => :void
  (let* ((p (event-start (last-command-event)))
         (pr (hash-get self.presses (current-client)))
         (v (and p pr (posn-view p))))
    (when (and v (eq? v (selected-view)))
      (let ((anchor (pressed-position pr v))
            (position (text-position v p)))
        (when (and anchor position)
          (select-between! v anchor position (press-mode pr) dragging?: #t))))))

;; Emacs `mouse-set-region`: the region from the press to the release, or
;; to point when the release names no position in the text pressed in;
;; without a press in the view, a click where the release was.
(def (set-region-from-release! (self : mouse-state)) => :void
  (let* ((p (pointer-posn "mouse-set-region"))
         (pr (hash-get self.presses (current-client))))
    (hash-remove! self.presses (current-client))
    (let (v (and p (select-posn-view p)))
      (when v
        (let (anchor (and pr (pressed-position pr v)))
          (if anchor
            (select-between! v anchor (or (text-position v p) (view-point v)) (press-mode pr))
            (let (end (or (focus-position! v p) (and (view-node v) (view-point v))))
              (when end
                (select-between! v end end (click-mode (event-clicks)))))))))))

;; Emacs `mouse-set-point`: point where the click was; a double or triple
;; click selects the word or the line there.
(def (set-point-from-click! (self : mouse-state)) => :void
  (let (p (pointer-posn "mouse-set-point"))
    (hash-remove! self.presses (current-client))
    (let (v (and p (select-posn-view p)))
      (when v
        (let (position (focus-position! v p))
          (if position
            (select-between! v position position (click-mode (event-clicks)))
            (report-gone-line p)))))))

(def (define-mouse-commands! (ctx : context)) => :void
  (using (self (mouse-state presses: (make-hash-table-eq weak-keys: #t)) : mouse-state)
    (define-command ctx (mouse-set-point)
      "Select the view clicked in and move its point to where the click was, deactivating the region; a double click selects the word there, a triple click the line."
      (set-point-from-click! self))
    (define-command ctx (mouse-drag-region)
      "Select the view pressed in and move its point to where the press was; dragging then selects the text dragged over."
      (drag-region! self #f))
    (define-command ctx (mouse-drag-region-shift-adjust)
      "Select the view pressed in and extend its region, from the mark if it is active and from point otherwise, to where the press was."
      (drag-region! self #t))
    (define-command ctx (mouse-drag-movement)
      "Move point to where the held mouse button moved, selecting the text from where it was pressed."
      (drag-movement! self))
    (define-command ctx (mouse-set-region)
      "Set the region to the text from where the mouse button was pressed to where it was released."
      (set-region-from-release! self))
    (keymap-set ctx "<view> <mouse-1>" 'mouse-set-point)
    (keymap-set ctx "<view> <down-mouse-1>" 'mouse-drag-region)
    (keymap-set ctx "<view> <S-down-mouse-1>" 'mouse-drag-region-shift-adjust)
    (keymap-set ctx "<view> <mouse-movement>" 'mouse-drag-movement)
    (keymap-set ctx "<view> <drag-mouse-1>" 'mouse-set-region)
    (keymap-set ctx "<view> <S-mouse-1>" 'mouse-set-region)))
