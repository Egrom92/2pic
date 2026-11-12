#!/bin/bash
# Удаление 2pic:
#   curl -fsSL https://raw.githubusercontent.com/Egrom92/2pic/main/uninstall.sh | bash
set -u
osascript -e 'tell application id "local.2pic" to quit' >/dev/null 2>&1
pkill -x 2pic 2>/dev/null
sleep 0.5
for app in /Applications/2pic.app "$HOME/Applications/2pic.app"; do
    if [ -d "$app" ]; then
        # убрать 2pic из «Объектов входа», пока приложение ещё на месте
        open -n -W "$app" --args --unregister-login >/dev/null 2>&1
        rm -rf "$app" && echo "Удалено: $app"
    fi
done

KC="$HOME/Library/Keychains/2pic-signing.keychain-db"
if [ -f "$KC" ]; then
    rest=$(security list-keychains -d user | tr -d '"' | grep -v "2pic-signing" | xargs)
    # shellcheck disable=SC2086
    security list-keychains -d user -s $rest
    security delete-keychain "$KC" 2>/dev/null
    echo "Удалён сертификат подписи 2pic"
fi
rm -f "$HOME/Library/Logs/2pic.log"
rm -rf "$HOME/Library/Logs/2pic" "$HOME/Library/Logs/2pic-scroll-failures" "$HOME/Library/Application Support/2pic"
defaults delete local.2pic >/dev/null 2>&1

echo "✅ 2pic удалён. Снимки и видео на рабочем столе остались."
echo "   Разрешения можно убрать в Системных настройках → Конфиденциальность и безопасность."
