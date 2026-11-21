# faces

The shared face names, such as `faces:keyword` or `faces:diagnostic.error`, and their default look. A span's `face` names one or a list; views draws it as `data-face`, and a rule styles each family (`keyword` covers `keyword.return`). Each face has seven tokens, one per CSS property it sets, such as `--faces-keyword-color` and `--faces-keyword-font-weight`, so a theme or `user.css` changes one attribute of one face.
