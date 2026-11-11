# fedit

Outil en ligne de commande qui applique des remplacements de texte littéraux
en **préservant le format du fichier** : BOM, UTF-8 ou Windows-1252, fins de
ligne LF/CRLF et absence de saut de ligne final.

Compilation (FreePascal) : `fpc -O2 -Xs fedit.pas`

```
fedit info FICHIER...
fedit apply [--dry-run] [--check "COMMANDE {}"] PATCH|-
```

Format du patch (UTF-8, sans échappement) :

```
@@@ chemin/du/fichier
<<<<            (ou "<<<< x2" pour attendre 2 occurrences)
texte à trouver
====
remplacement
>>>>
```

Tout ou rien : si un bloc ne trouve pas le nombre attendu d'occurrences,
aucun fichier n'est modifié. Les fichiers à fins de ligne mixtes sont refusés.
