# Markdown in Tuna

Replies from a **language model** are drawn as Markdown: *emphasis*, **bold**,
~~struck~~ and `inline code`, in a proportional font. Links such as
[Gerbil](https://cons.io) and https://github.com/mity/md4c open in a new tab.

## Lists

- Paragraphs, headings, items and code are **text**: move, select and copy.
- Tables and rules are one item each.
  1. Ordered lists count from their first number.
  2. And nest.
- [x] Task items show their box
- [ ] Even when not done

## Code

```scheme
(def (greet (name : :string)) => :string
  (string-append "Hello, " name "!"))
```

> A quote, with `code` and a [link](https://example.org "Example").

| Block     | Drawn as        |  Lines |
|:----------|:---------------:|-------:|
| Paragraph | a text node     |   many |
| Table     | one rich node   |      1 |

---

Raw HTML stays text: <script>alert(1)</script>, and [this](javascript:alert(1)) is not a link.
