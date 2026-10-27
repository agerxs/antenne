#!/bin/bash
# Diagnostic d'un abonnement Xtream : état du compte, puis test d'un échantillon de chaînes
# avec ffprobe. N'affiche ni lien ni identifiant : le résultat peut être partagé tel quel.
#
# Usage : bash scripts/diagnostic-flux.sh [nombre de chaînes à tester, 40 par défaut]

set -u
SAMPLE=${1:-40}
# Beaucoup de panneaux Xtream coupent la connexion quand l'agent est « curl ».
AGENT=${AGENT:-"VLC/3.0.21 LibVLC/3.0.21"}

for tool in curl ffprobe python3 perl; do
    command -v "$tool" >/dev/null || { echo "Outil manquant : $tool"; exit 1; }
done

printf 'Serveur (ex. http://serveur.com:8080) : '; read -r SERVER
printf 'Utilisateur : '; read -r USERNAME
printf 'Mot de passe : '; read -rs PASSWORD; echo
case "$SERVER" in *://*) ;; *) SERVER="http://$SERVER" ;; esac
SERVER=${SERVER%/}

WORK=$(mktemp -d)
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

# Retire toute URL d'un message d'erreur avant de l'afficher.
scrub() { sed -E 's#[a-zA-Z]+://[^ ]+#<lien>#g'; }
# Coupe une commande qui ne rend pas la main (macOS n'a pas `timeout`).
with_timeout() { perl -e 'alarm shift; exec @ARGV' "$@"; }

echo
echo "== Compte"
code=$(curl -s -A "$AGENT" --max-time 40 -w '%{http_code}' --get "$SERVER/player_api.php" \
    --data-urlencode "username=$USERNAME" --data-urlencode "password=$PASSWORD" -o "$WORK/account.json")
echo "(HTTP $code)"
python3 -I - "$WORK/account.json" <<'PY'
import json, sys, datetime
try:
    info = json.load(open(sys.argv[1])).get("user_info", {})
except Exception:
    print("Réponse illisible (vide ou pas du JSON) : serveur injoignable ou trop lent."); sys.exit()
if info.get("auth") == 0:
    print("Identifiants refusés par le serveur."); sys.exit()
exp = info.get("exp_date")
exp = datetime.datetime.fromtimestamp(int(exp)).strftime("%d/%m/%Y %H:%M") if exp else "?"
print(f"statut : {info.get('status', '?')} | essai : {info.get('is_trial', '?')} | expire : {exp}")
print(f"connexions : {info.get('active_cons', '?')} active(s) sur {info.get('max_connections', '?')} autorisée(s)")
print(f"formats autorisés : {', '.join(info.get('allowed_output_formats', [])) or '?'}")
PY

echo
echo "== Playlist (mêmes paramètres que l'app : m3u_plus, sortie m3u8, jusqu'à 4 min)"
curl -s -A "$AGENT" --max-time 240 --get "$SERVER/get.php" \
    --data-urlencode "username=$USERNAME" --data-urlencode "password=$PASSWORD" \
    --data-urlencode "type=m3u_plus" --data-urlencode "output=m3u8" -o "$WORK/playlist.m3u"

awk '
    { sub(/\r$/, "") }
    /^#EXTINF/ {
        group = ""
        if (match($0, /group-title="[^"]*"/)) group = substr($0, RSTART + 13, RLENGTH - 14)
        name = $0
        if (index(name, "\",") > 0) { while (index(name, "\",") > 0) name = substr(name, index(name, "\",") + 2) }
        else sub(/^[^,]*,/, "", name)
        next
    }
    /^[a-zA-Z]+:\/\// { print name "\037" group "\037" $0; name = ""; group = "" }
' "$WORK/playlist.m3u" > "$WORK/channels.tsv"

TOTAL=$(wc -l < "$WORK/channels.tsv" | tr -d ' ')
if [ "$TOTAL" -eq 0 ]; then
    echo "Aucune chaîne reçue. Début de la réponse :"
    head -c 300 "$WORK/playlist.m3u" | scrub; echo
    exit 1
fi
echo "$TOTAL entrées"
echo "extensions : $(cut -d$'\037' -f3 "$WORK/channels.tsv" | sed -E 's#\?.*##; s#.*/##' | awk -F. '{ print (NF > 1 ? $NF : "(aucune)") }' | sort | uniq -c | sort -rn | head -5 | awk '{ printf "%s %s  ", $1, $2 }')"
echo "types : $(cut -d$'\037' -f3 "$WORK/channels.tsv" | sed -E 's#^[a-zA-Z]+://[^/]+/##' | cut -d/ -f1 | sort | uniq -c | sort -rn | head -4 | awk '{ printf "%s %s  ", $1, $2 }')"

echo
echo "== Test de $SAMPLE chaînes réparties dans la liste (ferme Antenne et tout autre lecteur avant)"
awk -v total="$TOTAL" -v sample="$SAMPLE" 'BEGIN { step = total / sample; if (step < 1) step = 1 }
    NR == int(next_pick) + 1 { print; next_pick += step }' "$WORK/channels.tsv" > "$WORK/sample.tsv"

ok_apple=0; ok_vlc=0; dead=0; i=0
while IFS=$'\037' read -r name group url; do
    i=$((i + 1))
    code=$(curl -s -A "$AGENT" -o /dev/null -w '%{http_code}' --max-time 8 "$url")
    probe=$(with_timeout 25 ffprobe -v error -user_agent "$AGENT" -rw_timeout 10000000 \
        -show_entries stream=codec_type,codec_name -of csv=p=0 -i "$url" 2>"$WORK/err" | sort -u | tr '\n' ' ')
    case "$url" in *.m3u8*) container="HLS" ;; *.ts*) container="TS" ;; *) container="?" ;; esac

    if [ -z "$probe" ]; then
        verdict="ÉCHEC    "; dead=$((dead + 1))
        detail="HTTP $code, $(head -1 "$WORK/err" | scrub | cut -c1-70)"
    else
        video=$(echo "$probe" | grep -oE '[a-z0-9_]+,video' | cut -d, -f1 | head -1)
        audio=$(echo "$probe" | grep -oE '[a-z0-9_]+,audio' | cut -d, -f1 | head -1)
        detail="$container, vidéo ${video:-aucune}, audio ${audio:-aucun}"
        if [ "$container" = "HLS" ] && echo "${video:-h264}" | grep -qE '^(h264|hevc)$' \
            && echo "${audio:-aac}" | grep -qE '^(aac|mp3|ac3|eac3)$'; then
            verdict="APPLE OK "; ok_apple=$((ok_apple + 1))
        else
            verdict="VLC SEUL "; ok_vlc=$((ok_vlc + 1))
        fi
    fi
    printf '%2d. %s %-32.32s %-18.18s %s\n' "$i" "$verdict" "$name" "$group" "$detail"
    sleep 1
done < "$WORK/sample.tsv"

echo
echo "== Résumé sur $i chaînes testées"
echo "lisibles par le lecteur d'Apple : $ok_apple"
echo "lisibles seulement avec VLCKit  : $ok_vlc"
echo "en échec pour tout le monde     : $dead"
