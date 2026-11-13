# fedit

Outil en ligne de commande qui applique des remplacements de texte littéraux
en **préservant le format du fichier** : BOM, UTF-8 ou Windows-1252, fins de
ligne LF/CRLF et absence de saut de ligne final.

Compilation (FreePascal) : `fpc -O2 -Xs -WR fedit.pas`

`-WR` ajoute la table de relocation : sans elle, Windows refuse de lancer l'exécutable quand l'ASLR obligatoire est activé (« Repositionnement de DLL système non autorisé »).

```
fedit info FICHIER...
fedit cat [-n] FICHIER [A-B]
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

Un même fichier peut apparaître sous plusieurs en-têtes `@@@` (chemins écrits
différemment compris) : ses blocs s'appliquent dans l'ordre sur le même texte,
chacun voyant le résultat des précédents. Avant la correction, la dernière
section écrasait silencieusement les précédentes.

Tout ou rien : si un bloc ne trouve pas le nombre attendu d'occurrences,
aucun fichier n'est modifié. Les fichiers à fins de ligne mixtes sont refusés.

Sous Windows, les chemins POSIX (`/c/dossier`, `/mnt/c/dossier`, `/cygdrive/c/dossier`) sont acceptés, y compris dans les en-têtes `@@@` du patch.

Tests : `FEDIT=chemin/fedit ./test.sh` (bash ; fichiers jetables).

`cat` affiche un fichier en UTF-8, fins de ligne LF, sans BOM (le format détecté va sur stderr) ; `A-B` limite aux lignes demandées et `-n` numérote.
