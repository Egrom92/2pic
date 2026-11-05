#!/bin/bash
# Один раз создаёт локальный самоподписанный сертификат для подписи 2pic.
# Разрешения macOS (запись экрана, универсальный доступ) привязаны к подписи,
# поэтому с постоянным сертификатом их не нужно выдавать заново после каждой пересборки.
# Сертификат лежит в отдельной связке ключей, чтобы codesign не спрашивал пароль.
set -euo pipefail
NAME="2pic Local Signing"
KC="$HOME/Library/Keychains/2pic-signing.keychain-db"
KCPASS="2pic-local-signing"   # не секрет: защищает только этот локальный ключ подписи

add_to_search_list() {   # codesign ищет ключи только в связках из списка пользователя
    if ! security list-keychains -d user | grep -q "2pic-signing"; then
        local cur; cur=$(security list-keychains -d user | tr -d '"' | xargs)
        # shellcheck disable=SC2086
        security list-keychains -d user -s $cur "$KC"
    fi
}

if [ -f "$KC" ] && security find-certificate -c "$NAME" "$KC" >/dev/null 2>&1; then
    add_to_search_list
    echo "Сертификат «$NAME» уже есть."; exit 0
fi

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/cfg" <<CFG
[req]
distinguished_name=dn
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CFG
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -config "$tmp/cfg" -extensions ext 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -out "$tmp/id.p12" -passout pass:tmp -name "$NAME"

[ -f "$KC" ] || security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings "$KC"            # без автоблокировки
security unlock-keychain -p "$KCPASS" "$KC"
security import "$tmp/id.p12" -k "$KC" -P tmp -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null
add_to_search_list
echo "Создан сертификат «$NAME» в $KC"
