#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="DriveCheckMenu"
CONFIG="${CONFIG:-release}"
APP_DIR="build/${APP_NAME}.app"
BUNDLE_ID="de.chriswit.DriveCheckMenu"

ARCH_ARGS=""
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    ARCH_ARGS="--arch arm64 --arch x86_64"
    echo "Baue Universal Binary (arm64 + x86_64) …"
else
    echo "Baue für die aktuelle Architektur …"
fi

swift build -c "$CONFIG" ${ARCH_ARGS} --product "$APP_NAME"
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_ARGS} --show-bin-path)"
BIN="${BIN_DIR}/${APP_NAME}"

if [[ ! -f "${BIN}" ]]; then
    echo "Fehler: Binary nicht gefunden: ${BIN}" >&2
    exit 1
fi

if [[ ! -f Resources/AppIcon.icns || scripts/make-icns.swift -nt Resources/AppIcon.icns ]]; then
    echo "Erzeuge App-Icon …"
    (cd "$(pwd)" && swift scripts/make-icns.swift)
fi

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

cp "${BIN}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP_DIR}/Contents/Info.plist"
cp Resources/AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

# Prefer an Apple Development identity (more reliable for SMAppService login items),
# otherwise fall back to ad-hoc signing.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "${IDENTITY}" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -n 1)"
fi

if [[ -n "${IDENTITY}" ]]; then
    echo "Signiere mit: ${IDENTITY}"
    if ! codesign --force --deep --sign "${IDENTITY}" "${APP_DIR}" >/dev/null 2>&1; then
        echo "Signatur mit ${IDENTITY} fehlgeschlagen (Keychain-Zugriff?) – verwende ad-hoc Signatur."
        codesign --force --deep --sign - "${APP_DIR}" >/dev/null
    fi
else
    echo "Keine Signaturidentität gefunden – verwende ad-hoc Signatur."
    codesign --force --deep --sign - "${APP_DIR}" >/dev/null
fi

codesign --verify --deep --strict "${APP_DIR}"
echo "OK – Bundle erstellt: ${APP_DIR}"
echo "Start mit: open ${APP_DIR}"
