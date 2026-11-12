#!/usr/bin/env bash
# Tests de fedit apply sur des fichiers jetables.
# Usage : FEDIT=/chemin/fedit.exe ./test.sh   (par défaut : fedit du PATH)
set -u
FEDIT=${FEDIT:-fedit}
T=$(mktemp -d)
# Sous Git Bash/MSYS, un exécutable Windows ne comprend pas /tmp/... : chemin Windows (C:/...).
command -v cygpath >/dev/null && T=$(cygpath -m "$T")
trap 'rm -rf "$T"' EXIT
fail=0

check() { # nom attendu réel
  if [ "$2" == "$3" ]; then echo "ok    $1"; else echo "ECHEC $1 : attendu [$2], obtenu [$3]"; fail=1; fi
}
content() { tr '\n' ' ' < "$1"; }

# 1. un en-tête, plusieurs blocs
printf 'one\ntwo\nthree\nfour\n' > "$T/a.txt"
$FEDIT apply - >/dev/null <<PATCH
@@@ $T/a.txt
<<<<
one
====
ONE
>>>>
<<<<
three
====
THREE
>>>>
PATCH
check "un en-tête, deux blocs" "ONE two THREE four " "$(content "$T/a.txt")"

# 2. en-tête répété pour le même fichier : toutes les modifications comptent
printf 'one\ntwo\nthree\nfour\n' > "$T/b.txt"
$FEDIT apply - >/dev/null <<PATCH
@@@ $T/b.txt
<<<<
one
====
ONE
>>>>
@@@ $T/b.txt
<<<<
three
====
THREE
>>>>
PATCH
check "en-tête répété" "ONE two THREE four " "$(content "$T/b.txt")"

# 3. un bloc ultérieur peut s'appuyer sur le résultat du précédent, même avec en-tête répété
printf 'alpha\n' > "$T/c.txt"
$FEDIT apply - >/dev/null <<PATCH
@@@ $T/c.txt
<<<<
alpha
====
beta
>>>>
@@@ $T/c.txt
<<<<
beta
====
gamma
>>>>
PATCH
check "blocs enchaînés" "gamma " "$(content "$T/c.txt")"

# 4. deux fichiers dans le même patch, l'un avec en-tête répété
printf 'x1\nx2\n' > "$T/d.txt"; printf 'y1\ny2\n' > "$T/e.txt"
$FEDIT apply - >/dev/null <<PATCH
@@@ $T/d.txt
<<<<
x1
====
X1
>>>>
@@@ $T/e.txt
<<<<
y1
====
Y1
>>>>
@@@ $T/d.txt
<<<<
x2
====
X2
>>>>
PATCH
check "deux fichiers, entrelacés (d)" "X1 X2 " "$(content "$T/d.txt")"
check "deux fichiers, entrelacés (e)" "Y1 y2 " "$(content "$T/e.txt")"

# 5. même fichier écrit de deux façons (chemin absolu et chemin relatif)
printf 'p\nq\n' > "$T/f.txt"
( cd "$T" && $FEDIT apply - >/dev/null <<PATCH
@@@ f.txt
<<<<
p
====
P
>>>>
@@@ $T/f.txt
<<<<
q
====
Q
>>>>
PATCH
)
check "chemin relatif et absolu" "P Q " "$(content "$T/f.txt")"

# 6. tout ou rien : un bloc introuvable dans la seconde section, rien n'est écrit
printf 'k\nl\n' > "$T/g.txt"
$FEDIT apply - >/dev/null 2>&1 <<PATCH
@@@ $T/g.txt
<<<<
k
====
K
>>>>
@@@ $T/g.txt
<<<<
absent
====
Z
>>>>
PATCH
rc=$?
check "tout ou rien (fichier)" "k l " "$(content "$T/g.txt")"
check "tout ou rien (code de sortie)" "2" "$rc"

# 7. le format est préservé (CRLF, BOM) avec en-tête répété
printf '\xEF\xBB\xBFa\r\nb\r\nc' > "$T/h.txt"
$FEDIT apply - >/dev/null <<PATCH
@@@ $T/h.txt
<<<<
a
====
A
>>>>
@@@ $T/h.txt
<<<<
c
====
C
>>>>
PATCH
check "BOM + CRLF + pas de saut final" "efbbbf410d0a620d0a43" "$(od -An -tx1 -v "$T/h.txt" | tr -d ' \n')"

[ $fail -eq 0 ] && echo "tout est ok" || echo "des tests ont échoué"
exit $fail
