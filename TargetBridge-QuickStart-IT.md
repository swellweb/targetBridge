# TargetBridge Quick Start (Italiano)

## Contenuto del pacchetto

- `TargetBridge-Sender`
- `TargetBridge-Receiver`

## Build del sender

```bash
cd TargetBridge-Sender
./scripts/build_targetbridge_sender_app.sh
```

App prodotta:

- `~/Desktop/TargetBridge.app`

## Build del receiver

Prima di buildare, installa le dipendenze necessarie sull'iMac:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install ffmpeg sdl2 pkg-config
```

Poi builda:

```bash
cd TargetBridge-Receiver
./scripts/build_tbreceiver_c_app.sh
```

App prodotta:

- `~/Desktop/TargetBridge Receiver.app`

Nota:

- sull'iMac Intel il receiver va buildato direttamente sull'iMac, cosi' la binaria risultante sara' `x86_64`

## Avvio

### MacBook

Apri:

- `TargetBridge.app`

Alla prima esecuzione concedi:

- `Registrazione Schermo`

### iMac

Apri:

- `TargetBridge Receiver.app`

Annota l'IP mostrato nella finestra iniziale.

## Collegamento

1. Avvia prima `TargetBridge Receiver` sull'iMac
2. Leggi l'IP Thunderbolt Bridge mostrato dal receiver
3. Apri `TargetBridge` sul MacBook
4. Inserisci quell'IP nel campo `IP receiver`
5. Premi `Connetti`

Quando arriva il primo frame, il receiver passa automaticamente in fullscreen.

## Profili stream

- `Standard · 2560 × 1440`
  - latenza piu' bassa
  - maggiore stabilita'
  - nitidezza inferiore al 5K nativo

- `5K · 5120 × 2880`
  - piu' nitido
  - usa `HEVC`
  - maggiore carico e latenza leggermente superiore

## Avvio automatico del receiver

Per avviare il receiver automaticamente al login dell'utente iMac:

```bash
cd TargetBridge-Receiver
./scripts/install_tbreceiverc_launch_agent.sh
```

Per rimuoverlo:

```bash
cd TargetBridge-Receiver
./scripts/uninstall_tbreceiverc_launch_agent.sh
```

## Note pratiche

- il receiver deve essere avviato prima del sender
- il sender puo' mostrare o nascondere l'icona topbar
- se il 5K non e' abbastanza reattivo, torna al profilo `Standard`
- il build script del sender usa una DerivedData locale in `TargetBridge-Sender/.build/DerivedData`
