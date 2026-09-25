#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
DOMAIN=${LOCAL_DOMAIN:-finntrail.local}
CERT_DIR="$ROOT_DIR/confs/nginx/certs/$DOMAIN"
CERT_FILE="$CERT_DIR/fullchain.pem"
KEY_FILE="$CERT_DIR/privkey.pem"
PHP_CA_DIR="$ROOT_DIR/confs/php/local-ca"
PHP_CA_FILE="$PHP_CA_DIR/rootCA.pem"

prepare_php_ca() {
    source_ca=$1

    if ! command -v openssl >/dev/null 2>&1; then
        echo "openssl is required to prepare the PHP trust store." >&2
        exit 1
    fi
    if [ ! -s "$source_ca" ]; then
        echo "mkcert root CA was not found: $source_ca" >&2
        exit 1
    fi

    mkdir -p "$PHP_CA_DIR"
    if [ "$source_ca" != "$PHP_CA_FILE" ]; then
        cp -f "$source_ca" "$PHP_CA_FILE"
    fi

    for old_hash in "$PHP_CA_DIR"/*.0; do
        if [ -e "$old_hash" ] || [ -L "$old_hash" ]; then
            rm -f -- "$old_hash"
        fi
    done

    ca_hash=$(openssl x509 -in "$PHP_CA_FILE" -noout -hash)
    case "$ca_hash" in
        ""|*[!0-9A-Fa-f]*)
            echo "Could not calculate the mkcert CA hash." >&2
            exit 1
            ;;
    esac

    ln -sfn rootCA.pem "$PHP_CA_DIR/$ca_hash.0"
    chmod 0644 "$PHP_CA_FILE"
}

is_wsl() {
    [ -r /proc/sys/kernel/osrelease ] && grep -qi microsoft /proc/sys/kernel/osrelease
}

if is_wsl; then
    if [ -s "$CERT_FILE" ] &&
        [ -s "$KEY_FILE" ] &&
        [ -s "$PHP_CA_FILE" ] &&
        openssl verify \
            -CAfile "$PHP_CA_FILE" \
            "$CERT_FILE" >/dev/null 2>&1; then
        chmod 0644 "$CERT_FILE" "$KEY_FILE"
        prepare_php_ca "$PHP_CA_FILE"
        echo "Existing valid WSL certificate and CA were reused."
        exit 0
    fi

    if ! command -v powershell.exe >/dev/null 2>&1 || ! command -v wslpath >/dev/null 2>&1; then
        echo "Windows PowerShell and wslpath are required in WSL." >&2
        exit 1
    fi

    WINDOWS_SCRIPT=$(wslpath -w "$ROOT_DIR/scripts/setup-local-cert.ps1")
    WINDOWS_ROOT=$(wslpath -w "$ROOT_DIR")
    powershell.exe -NoProfile -ExecutionPolicy Bypass \
        -File "$WINDOWS_SCRIPT" \
        -ProjectRoot "$WINDOWS_ROOT" \
        -Domain "$DOMAIN"

    if [ ! -s "$CERT_FILE" ] || [ ! -s "$KEY_FILE" ]; then
        echo "Certificate setup finished, but the expected files were not created:" >&2
        echo "  $CERT_FILE" >&2
        echo "  $KEY_FILE" >&2
        echo "Run ./scripts/setup-local-cert.sh again and check the PowerShell/UAC error." >&2
        exit 1
    fi

    # The Nginx image runs as a non-root user and must be able to read the key.
    chmod 0644 "$CERT_FILE" "$KEY_FILE"
    prepare_php_ca "$PHP_CA_FILE"
    echo "Local certificate configured for WSL + Windows."
    exit 0
fi

OS=$(uname -s)
case "$OS" in
    Darwin)
        if ! command -v mkcert >/dev/null 2>&1; then
            if ! command -v brew >/dev/null 2>&1; then
                echo "Homebrew is required to install mkcert on macOS: https://brew.sh" >&2
                exit 1
            fi
            brew install mkcert
        fi
        MKCERT=$(command -v mkcert)
        ;;
    Linux)
        if command -v mkcert >/dev/null 2>&1; then
            MKCERT=$(command -v mkcert)
        else
            if ! command -v curl >/dev/null 2>&1; then
                echo "curl is required to download mkcert." >&2
                exit 1
            fi
            MKCERT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/mkcert-bin"
            MKCERT="$MKCERT_DIR/mkcert"
            mkdir -p "$MKCERT_DIR"
            curl -fsSL "https://dl.filippo.io/mkcert/latest?for=linux/amd64" -o "$MKCERT"
            chmod 0755 "$MKCERT"
        fi
        ;;
    *)
        echo "Unsupported operating system: $OS" >&2
        exit 1
        ;;
esac

"$MKCERT" -install

MKCERT_CA_ROOT=$("$MKCERT" -CAROOT)
prepare_php_ca "$MKCERT_CA_ROOT/rootCA.pem"

mkdir -p "$CERT_DIR"
TEMP_DIR=$(mktemp -d)
cleanup() {
    rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT HUP INT TERM

"$MKCERT" \
    -cert-file "$TEMP_DIR/fullchain.pem" \
    -key-file "$TEMP_DIR/privkey.pem" \
    "$DOMAIN" localhost 127.0.0.1 ::1

mv -f "$TEMP_DIR/fullchain.pem" "$CERT_FILE"
mv -f "$TEMP_DIR/privkey.pem" "$KEY_FILE"
chmod 0644 "$CERT_FILE" "$KEY_FILE"

if ! awk -v host="$DOMAIN" '
    {
        for (i = 2; i <= NF; i++) {
            if ($i == host) found = 1
        }
    }
    END { exit(found ? 0 : 1) }
' /etc/hosts; then
    printf '\n127.0.0.1\t%s\n' "$DOMAIN" | sudo tee -a /etc/hosts >/dev/null
fi

echo "Local HTTPS certificate is ready: $CERT_FILE"
echo "Open https://$DOMAIN after Docker Compose starts."
