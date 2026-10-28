;;; Markdown: Markdown text drawn as buffer nodes, and Markdown being typed
;;; styled in place (docs/briefs/2026-10-agent-chat.md). The input is
;;; untrusted, such as a language model's reply: raw HTML is shown as
;;; text, and only http, https and mailto links open.
;;;
;;; Block nodes. `markdown-blocks` turns Markdown into one node per block,
;;; of kinds the provider defines and draws: paragraphs, headings, list
;;; items and code are text nodes inside, holding the visible text, with
;;; inline styles (bold, italic, code, links) as highlight spans, so the
;;; cursor, selection and copying work on them; a table is one item with a
;;; text projection. Each top-level node has the attributes `key`, its
;;; index among the blocks, and `markdown`, its Markdown, so a caller can
;;; rebuild only the blocks that changed (`markdown-update-blocks`), as
;;; when a reply streams in.
;;;
;;; Styling Markdown being typed. `markdown-style-text!` styles a text's
;;; raw Markdown in its highlight layer `markdown`: headings larger, bold,
;;; italic and code as they will look, code blocks monospace, markers
;;; such as `**` and `#` dimmed; and styles it again after every change,
;;; while the provider runs, for a prompt someone is typing.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        :tuna/plugins/buffers/contract)
(export (interface-out Markdown)
        markdown-service
        markdown-blocks
        markdown-update-blocks
        markdown-style-text!)

(interface Markdown
  (blocks (source : :string)) => :list
  (update-blocks (nodes : :list) (source : :string)) => :list
  (style-text! (t : text)) => :void)

(def markdown-service
  (new-service 'markdown is-Markdown? tier: 'live
               doc: "Draws Markdown as buffer nodes and styles Markdown being typed."))

;; SOURCE's blocks as new nodes, in order.
(def (markdown-blocks (source : :string)) => :list
  (:- (with-service-provider (provider markdown-service Markdown)
        (Markdown-blocks provider source))
      :list))

;; SOURCE's blocks as nodes, taking from NODES, earlier blocks' nodes,
;; each node whose block has the same key and Markdown as before, and
;; making new ones for the rest. NODES must be the children of the node
;; that is to hold the result (set-node-children!), or have no parent.
(def (markdown-update-blocks (nodes : :list) (source : :string)) => :list
  (:- (with-service-provider (provider markdown-service Markdown)
        (Markdown-update-blocks provider nodes source))
      :list))

;; Style T's Markdown in its highlight layer `markdown`, now and after
;; each change to T.
(def (markdown-style-text! (t : text)) => :void
  (with-service-provider (provider markdown-service Markdown)
    (Markdown-style-text! provider t)))
