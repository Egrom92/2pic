#!/bin/bash
# Установка или обновление 2pic одной командой:
#   curl -fsSL https://raw.githubusercontent.com/Egrom92/2pic/main/install.sh | bash
# или из скачанной папки:  ./install.sh
set -euo pipefail

REPO="Egrom92/2pic"
say() { printf '\n\033[1m▶︎ %s\033[0m\n' "$*"; }
die() { printf '\n❌ %s\n' "$*" >&2; exit 1; }

# --- 1. Система ---------------------------------------------------------------
[ "$(uname -s)" = Darwin ] || die "2pic работает только на macOS."
ver=$(sw_vers -productVersion)
[ "${ver%%.*}" -ge 14 ] || die "Нужна macOS 14 Sonoma или новее (у вас $ver)."

# --- 2. Инструменты разработчика (компилятор Swift) ---------------------------
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swift >/dev/null 2>&1; then
    say "Нужны бесплатные инструменты разработчика Apple (Command Line Tools)"
    echo "Сейчас откроется окно установки: нажмите «Установить», дождитесь окончания"
    echo "(5–15 минут) и запустите эту же команду ещё раз."
    xcode-select --install 2>/dev/null || true
    exit 1
fi

# --- 3. Исходники: из этой папки или свежие с GitHub --------------------------
SRC=""
self="${BASH_SOURCE[0]:-}"
if [ -n "$self" ] && [ -f "$(dirname "$self")/Package.swift" ] && [ -d "$(dirname "$self")/Sources/TwoPic" ]; then
    SRC="$(cd "$(dirname "$self")" && pwd)"
else
    say "Скачиваю 2pic с GitHub"
    TMP=$(mktemp -d "${TMPDIR:-/tmp}/2pic.XXXXXX")
    trap 'rm -rf "$TMP"' EXIT
    curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.tar.gz" | tar -xz -C "$TMP" \
        || die "Не удалось скачать https://github.com/$REPO. Проверьте интернет."
    SRC="$TMP/2pic-main"
fi
cd "$SRC"

# --- 4. Сборка ----------------------------------------------------------------
say "Собираю 2pic (первый раз 1–3 минуты)"
if ! ./scripts/build.sh >"${TMPDIR:-/tmp}/2pic-build.log" 2>&1; then
    tail -30 "${TMPDIR:-/tmp}/2pic-build.log" >&2
    die "Сборка не удалась. Обновите Command Line Tools (Системные настройки → Основные → Обновление ПО) и попробуйте снова. Полный журнал: ${TMPDIR:-/tmp}/2pic-build.log"
fi

# --- 5. Установка ---------------------------------------------------------------
DEST=/Applications
if [ ! -w "$DEST" ]; then
    DEST="$HOME/Applications"   # у обычного (не администратора) пользователя нет прав на /Applications
    mkdir -p "$DEST"
fi
say "Ставлю в $DEST/2pic.app"
osascript -e 'tell application id "local.2pic" to quit' >/dev/null 2>&1 || true
pkill -x 2pic 2>/dev/null || true
sleep 0.5
rm -rf "$DEST/2pic.app"
ditto build/2pic.app "$DEST/2pic.app"
open "$DEST/2pic.app"

cat <<'DONE'

✅ 2pic установлен и запущен — значок с рамкой и стрелкой в строке меню справа вверху.

Осталось один раз выдать разрешения
(Системные настройки → Конфиденциальность и безопасность):

  1. «Запись экрана и системного звука» → включите 2pic.
     macOS сама предложит это при первом снимке. После включения перезапустите 2pic
     (значок в строке меню → «Выйти из 2pic», затем откройте 2pic из Программ).
  2. «Универсальный доступ» → «+» → 2pic. Нужно только для снимка с прокруткой (⌘⇧8).

Горячие клавиши:
  ⌘⇧9  снимок области или окна (там же — запись видео: кнопка ⏺ или V)
  ⌘⇧8  снимок с прокруткой
  ⌘C / Enter — скопировать, Esc — отмена, ⌘S — сохранить на рабочий стол

2pic сам запускается при входе в систему. Обновить — запустить эту же команду ещё раз.
DONE
