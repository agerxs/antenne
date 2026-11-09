#!/bin/bash
# Empaquette Antenne (app web Tizen), la signe et l'installe sur un téléviseur Samsung en mode développeur.
# Usage : bash scripts/install-tv.sh <ip-du-téléviseur> [profil-de-certificat]
# Le profil (Certificate Manager de Tizen Studio) doit contenir le DUID du téléviseur.
set -euo pipefail
TV_IP="${1:?Adresse IP du téléviseur manquante}"
PROFILE="${2:-antenne}"
TIZEN="$HOME/tizen-studio/tools/ide/bin/tizen"
SDB="$HOME/tizen-studio/tools/sdb"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

cp -R "$ROOT/config.xml" "$ROOT/index.html" "$ROOT/icon.png" "$ROOT/css" "$ROOT/js" "$BUILD/"
"$TIZEN" package -t wgt -s "$PROFILE" -- "$BUILD" >/dev/null
# Un nom de paquet sans espace ni parenthèse : sinon l'installation échoue sans message.
mv "$BUILD"/*.wgt "$BUILD/antenne.wgt"
"$SDB" connect "$TV_IP" >/dev/null
"$TIZEN" install -n antenne.wgt -s "$TV_IP:26101" -- "$BUILD" | grep -E "successfully|Failed"
"$TIZEN" run -p AntenneWeb.Antenne -s "$TV_IP:26101" | tail -1
