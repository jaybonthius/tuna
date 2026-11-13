# modes

Major and minor modes. A buffer has one major mode, such as Scheme or Markdown, which gives it a keymap, a lighter and the local option values its hooks set; switching it drops the buffer's local values. A minor mode is a procedure of no arguments that says where a behaviour is on, usually an option, with its own keymap and lighter.
