#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
INSTALLER_APP="${1:?pass TargetBridge Installer.app as first argument}"
OUTPUT_DIR="${2:?pass output directory as second argument}"
PACKAGE_DIR="${OUTPUT_DIR}/TARGETBRIDGE"

[[ -d "${INSTALLER_APP}" ]] || {
    print -u2 -- "Installer app not found: ${INSTALLER_APP}"
    exit 2
}

/bin/mkdir -p "${OUTPUT_DIR}"
[[ ! -e "${PACKAGE_DIR}" ]] || /bin/rm -R "${PACKAGE_DIR}"
/bin/mkdir -p "${PACKAGE_DIR}"
/usr/bin/ditto "${INSTALLER_APP}" "${PACKAGE_DIR}/TargetBridge Installer.app"

/bin/cat > "${PACKAGE_DIR}/LEGGIMI - TARGETBRIDGE.txt" <<'EOF'
TARGETBRIDGE — MODALITÀ MONITOR IMAC

Apri “TargetBridge Installer.app”.

L’app riconosce automaticamente il computer:
- sull’iMac installa o aggiorna il ricevitore;
- sul Mac mini installa o aggiorna il trasmettitore.

Non è necessario aprire Terminale o usare file .command.
L’installazione conserva una copia della versione precedente e configura
l’avvio automatico. Per controllare il Mac mini dall’iMac basta autorizzare
TargetBridge in Accessibilità sul Mac mini. I permessi dell’iMac sono opzionali
e servono solo alla modalità di controllo globale avanzata. Sul Mac mini rimane
necessario anche il permesso Registrazione schermo per il video.

Il pulsante Stop interrompe la modalità monitor e la lascia ferma finché non
premi nuovamente Avvia dall’iMac. Se invece si scollega un cavo o cade la rete,
TargetBridge continua a tentare automaticamente il ripristino.
EOF

(
    cd "${PACKAGE_DIR}"
    /usr/bin/ditto -c -k --keepParent --norsrc --noextattr \
        "TargetBridge Installer.app" "TargetBridge-Installer.zip"
    /usr/bin/shasum -a 256 "TargetBridge-Installer.zip" > "SHA256SUMS.txt"
)

print -- "PACKAGED:${PACKAGE_DIR}"
