#!/usr/bin/env bash
# AgrarOpen Hof-Server als Proxmox-Container anlegen. In der Shell des Proxmox-Hosts (Rechenzentrum → Knoten → Shell):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/SkaFUU/AgrarOpen-Releases/main/proxmox.sh)"
# Legt einen schlanken Debian-Container an (offizielle Proxmox-Vorlage), holt die neueste AgrarOpen-Version,
# prüft deren Signatur und richtet den Hof-Server ein. Zum Schluss stehen Adresse, Hof-Code und QR-Code da.
# Ohne Rückfragen: AO_YES=1, dazu wahlweise AO_ID AO_HOST AO_IP (dhcp oder 192.168.1.20/24) AO_GW AO_BRIDGE
#   AO_STORAGE (Festplatte) AO_TSTORAGE (Vorlagen) AO_DISK (GB) AO_RAM (MB) AO_PW (root-Passwort)
set -euo pipefail

REPO=SkaFUU/AgrarOpen-Releases
# öffentlicher Schlüssel, mit dem jede AgrarOpen-Version signiert ist (wie im Hof-Server, server/update.ts)
PUB='MCowBQYDK2VwAyEAMVK/Azf423Ams9M88BR/uSX5o4o61u9yyRhelX4teC0='

if [ -t 1 ]; then G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' B=$'\e[1m' N=$'\e[0m'; else G='' Y='' R='' B='' N=''; fi
say() { echo "${G}»${N} $*"; }
die() { echo "${R}✗ $*${N}" >&2; exit 1; }
# ask VAR "Frage" Vorgabe – vorhandene Umgebungsvariable oder AO_YES=1 überspringt die Frage
ask() {
  local v="${!1:-}"
  if [ -z "$v" ] && [ "${AO_YES:-}" != 1 ] && [ -r /dev/tty ]; then read -r -p "  $2 [${3}]: " v </dev/tty || true; fi
  printf -v "$1" '%s' "${v:-$3}"
}

echo
echo "${B}AgrarOpen Hof-Server – Proxmox-Container einrichten${N}"
echo
command -v pct >/dev/null 2>&1 || die "Bitte in der Shell des Proxmox-Hosts starten (nicht in einem Container)."
[ "$(id -u)" = 0 ] || die "Bitte als root starten."
[ "$(dpkg --print-architecture)" = amd64 ] || die "Nur für Proxmox auf x86-64 (amd64)."
for c in curl openssl sha256sum pveam pvesm pvesh; do command -v $c >/dev/null 2>&1 || die "$c fehlt."; done

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ---------- 1. neueste Version holen und Signatur prüfen ----------
say "Neueste AgrarOpen-Version suchen"
DL="https://github.com/$REPO/releases/latest/download"
curl -fsSL -o "$TMP/m.json" "$DL/agraropen-update.json" || die "Kein Zugriff auf github.com."
curl -fsSL -o "$TMP/m.sig" "$DL/agraropen-update.json.sig"
printf -- '-----BEGIN PUBLIC KEY-----\n%s\n-----END PUBLIC KEY-----\n' "$PUB" > "$TMP/pub.pem"
base64 -d "$TMP/m.sig" > "$TMP/m.bin"
openssl pkeyutl -verify -pubin -inkey "$TMP/pub.pem" -rawin -in "$TMP/m.json" -sigfile "$TMP/m.bin" >/dev/null 2>&1 \
  || die "Signatur der Versionsliste stimmt nicht – abgebrochen."
VER=$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$TMP/m.json" | head -n1)
read -r TAR SHA < <(awk '/"linux-x64"/{f=1} f&&/"name"/{n=$0; gsub(/.*"name": *"|".*/,"",n)} f&&/"sha256"/{s=$0; gsub(/.*"sha256": *"|".*/,"",s); print n, s; exit}' "$TMP/m.json") || true
[ -n "$VER" ] && [ -n "${TAR:-}" ] && [ -n "${SHA:-}" ] || die "Versionsliste unvollständig."
echo "  Version $VER (Signatur gültig)"

# ---------- 2. Fragen ----------
say "Einstellungen (Enter = Vorschlag übernehmen)"
ask AO_ID "Container-Nummer" "$(pvesh get /cluster/nextid)"
pct status "$AO_ID" >/dev/null 2>&1 && die "Container $AO_ID gibt es schon."
ask AO_HOST "Name" "agraropen"
ROOTS=$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 && $3=="active"{print $1}' || true)
[ -n "$ROOTS" ] || die "Kein Speicher für Container gefunden."
DEF=$(echo "$ROOTS" | grep -qx local-lvm && echo local-lvm || echo "$ROOTS" | head -n1)
ask AO_STORAGE "Speicher für den Container ($(echo $ROOTS | tr ' ' ','))" "$DEF"
echo "$ROOTS" | grep -qx "$AO_STORAGE" || die "Speicher $AO_STORAGE gibt es nicht."
ask AO_DISK "Festplatte in GB" "4"
ask AO_RAM "Arbeitsspeicher in MB" "512"
ask AO_BRIDGE "Netzwerk-Brücke" "vmbr0"
ask AO_IP "Adresse: dhcp oder fest mit Maske, z. B. 192.168.1.20/24" "dhcp"
NET="name=eth0,bridge=$AO_BRIDGE,firewall=0"
if [ "$AO_IP" = dhcp ]; then NET="$NET,ip=dhcp"
else
  [[ "$AO_IP" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+/[0-9]+$ ]] || die "Adresse bitte so: 192.168.1.20/24"
  ask AO_GW "Gateway (Router)" "${BASH_REMATCH[1]}.1"
  NET="$NET,ip=$AO_IP,gw=$AO_GW"
fi
if [ -z "${AO_PW:-}" ] && [ "${AO_YES:-}" != 1 ] && [ -r /dev/tty ]; then
  read -r -s -p "  root-Passwort für die Konsole (leer = nur über »pct enter $AO_ID«): " AO_PW </dev/tty || true; echo
fi

# ---------- 3. Debian-Vorlage ----------
say "Debian-Vorlage besorgen"
TSTORES=$(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 && $3=="active"{print $1}' || true)
[ -n "$TSTORES" ] || die "Kein Speicher für Vorlagen (CT-Vorlagen) gefunden."
DEF=$(echo "$TSTORES" | grep -qx local && echo local || echo "$TSTORES" | head -n1)
AO_TSTORAGE=${AO_TSTORAGE:-$DEF}
pveam update >/dev/null 2>&1 || echo "  ${Y}Vorlagen-Liste konnte nicht erneuert werden, nehme die vorhandene.${N}"
T=""
for d in 13 12; do
  T=$(pveam available --section system 2>/dev/null | awk '{print $2}' | grep -E "^debian-$d-standard_.*_amd64\.tar\.(zst|gz|xz)$" | sort -V | tail -n1 || true)
  [ -n "$T" ] && break
done
[ -n "$T" ] || die "Keine Debian-Vorlage gefunden (pveam available)."
if pveam list "$AO_TSTORAGE" 2>/dev/null | grep -q "$T"; then echo "  $T ist schon da"
else pveam download "$AO_TSTORAGE" "$T" >/dev/null || die "Download der Vorlage fehlgeschlagen."; echo "  $T geladen"; fi

# ---------- 4. AgrarOpen laden ----------
say "AgrarOpen $VER laden"
curl -fsSL -o "$TMP/$TAR" "$DL/$TAR" || die "Download fehlgeschlagen."
echo "$SHA  $TMP/$TAR" | sha256sum -c --status || die "Prüfsumme stimmt nicht – Download beschädigt."

# ---------- 5. Container ----------
say "Container $AO_ID anlegen"
OPTS=(--hostname "$AO_HOST" --cores 1 --memory "$AO_RAM" --swap 256 --rootfs "$AO_STORAGE:$AO_DISK"
  --net0 "$NET" --unprivileged 1 --features nesting=1 --onboot 1 --ostype debian --timezone host
  --description "AgrarOpen Hof-Server – https://github.com/$REPO")
[ -n "${AO_PW:-}" ] && OPTS+=(--password "$AO_PW")
pct create "$AO_ID" "$AO_TSTORAGE:vztmpl/$T" "${OPTS[@]}" >/dev/null || die "Container konnte nicht angelegt werden."
pct set "$AO_ID" --tags agraropen >/dev/null 2>&1 || true
pct start "$AO_ID"

echo -n "  warte auf Netzwerk "
IP=""
for i in $(seq 1 60); do
  IP=$(pct exec "$AO_ID" -- hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -n1 || true)
  [ -n "$IP" ] && break; echo -n "."; sleep 1
done
echo " ${IP:-keine Adresse}"

say "AgrarOpen im Container einrichten"
pct push "$AO_ID" "$TMP/$TAR" /root/agraropen.tar.gz
pct exec "$AO_ID" -- sh -c 'cd /root && tar xzf agraropen.tar.gz && AGRAROPEN_CT=1 sh agraropen/install.sh >/root/agraropen-install.log 2>&1; r=$?; rm -rf agraropen agraropen.tar.gz; exit $r' \
  || die "Einrichten fehlgeschlagen – Protokoll: pct exec $AO_ID -- cat /root/agraropen-install.log"
# erster Start: Zertifikat und Hof-Code entstehen
for i in $(seq 1 30); do pct exec "$AO_ID" -- test -s /var/lib/agraropen/server.json 2>/dev/null && break; sleep 1; done

echo
echo "${G}${B}Fertig.${N} Container $AO_ID ($AO_HOST) startet ab jetzt mit Proxmox."
echo
pct exec "$AO_ID" -- /usr/local/bin/agraropen || true
if [ "$AO_IP" = dhcp ]; then
  MAC=$(pct config "$AO_ID" | sed -n 's/^net0:.*hwaddr=\([0-9A-Fa-f:]*\).*/\1/p')
  echo "  ${Y}Adresse per DHCP:${N} im Router für MAC ${B}${MAC:-?}${N} eine feste Adresse vergeben, dann  pct reboot $AO_ID"
  echo "  – am besten bevor Handy und PC verbunden werden (sie merken sich die Adresse)."
fi
echo "  Später wieder anzeigen: in der Container-Konsole, oder hier:  pct exec $AO_ID -- agraropen"
echo "  Updates kommen über die App (Einrichten → Betrieb und Daten → Hof-Server)."
echo
