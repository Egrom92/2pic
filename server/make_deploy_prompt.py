#!/usr/bin/env python3
"""Writes server/DEPLOY_PROMPT.md: the instructions for an AI assistant on the server, with twopic_server.py
inside and its checksum. Run after changing the server:  python3 server/make_deploy_prompt.py"""
import hashlib
import os

HERE = os.path.dirname(os.path.abspath(__file__))
code = open(os.path.join(HERE, "twopic_server.py"), encoding="utf-8").read()
digest = hashlib.sha256(code.encode("utf-8")).hexdigest()

TEMPLATE = r'''Ты администрируешь этот сервер. Разверни на нём приёмник ошибок и статистики для моего macOS-приложения **2pic** (скриншотер) и уведомления об ошибках в Telegram-бот. Код сервера уже написан и проверен — он целиком в конце, переписывать его не нужно. Твоя задача: установить, защитить, запустить и проверить.

## Как это устроено
- 2pic на Mac отправляет `POST <адрес>/v1/ingest` с заголовком `Authorization: Bearer <ключ>` и JSON: ошибки (с последними строками журнала перед ними), предупреждения, статистику использования, сведения о запуске и тестовые события. Снимков экрана и текста с них там нет.
- `twopic_server.py` (Python 3.9+, только стандартная библиотека, без pip) принимает данные, хранит их в SQLite и каждые 15 секунд отправляет новые ошибки в Telegram. Одинаковые ошибки он группирует, а повтор той же ошибки шлёт не чаще раза в 30 минут, подсчитывая пропущенные. Падение приложения приходит как «💥 2pic упал», тест из настроек 2pic — как «✅ 2pic на связи».
- Слушает только `127.0.0.1:8787`. Наружу его выпускает HTTPS-прокси: macOS не отправит данные по обычному http.

## Правила
- Ничего существующего не удаляй и не перезаписывай без моего подтверждения: другие сайты, конфиги веб-сервера, файрвол.
- Если не хватает root-доступа, домена или данных бота — остановись и спроси меня.
- Секреты (ключ, токен бота) не выводи целиком нигде, кроме итогового сообщения мне.

## Шаги
1. **Разведка.** Посмотри ОС, `python3 --version` (нужно ≥ 3.9), занятые порты 80/443/8787, есть ли уже веб-сервер (nginx, Caddy, Traefik, Apache), какие у сервера домены и публичный IP, включён ли файрвол. Коротко расскажи мне, что нашёл, и какой вариант HTTPS выбираешь (шаг 7).
2. **Пользователь и каталоги.** Создай системного пользователя `twopic` без входа в систему. Каталог `/opt/twopic` (код, владелец root, 755) и `/var/lib/twopic` (данные, владелец twopic, 700).
3. **Код.** Сохрани код из конца сообщения в `/opt/twopic/twopic_server.py` байт в байт (root:root, 755). Проверь: `sha256sum /opt/twopic/twopic_server.py` должен дать
   `__SHA__`
   Если сумма не совпала — файл повреждён при копировании. Не запускай его, скажи мне.
4. **Ключ доступа** для приложения: `openssl rand -hex 32` (или `python3 -c "import secrets; print(secrets.token_hex(32))"`).
5. **Telegram.**
   - Если на сервере уже есть бот для уведомлений, спроси меня, можно ли использовать его, и возьми его токен и chat id.
   - Иначе попроси меня: создать бота у @BotFather (команда `/newbot`) и прислать тебе токен, потом написать этому боту любое сообщение. Chat id возьми из `https://api.telegram.org/bot<ТОКЕН>/getUpdates` (поле `message.chat.id`).
6. **Настройки и служба.**
   `/etc/twopic.env` (владелец root, группа twopic, права 640):
   ```
   TWOPIC_TOKEN=<ключ из шага 4>
   TWOPIC_DB=/var/lib/twopic/twopic.db
   TWOPIC_LISTEN=127.0.0.1:8787
   TELEGRAM_BOT_TOKEN=<токен бота>
   TELEGRAM_CHAT_ID=<chat id>
   TWOPIC_REPEAT_MINUTES=30
   TWOPIC_RETENTION_DAYS=180
   ```
   `/etc/systemd/system/twopic.service`:
   ```
   [Unit]
   Description=2pic: errors and statistics receiver with Telegram notifications
   After=network-online.target
   Wants=network-online.target

   [Service]
   User=twopic
   Group=twopic
   EnvironmentFile=/etc/twopic.env
   ExecStart=/usr/bin/env python3 /opt/twopic/twopic_server.py serve
   Restart=always
   RestartSec=5
   NoNewPrivileges=yes
   ProtectSystem=strict
   ProtectHome=yes
   PrivateTmp=yes
   ReadWritePaths=/var/lib/twopic

   [Install]
   WantedBy=multi-user.target
   ```
   Затем `systemctl daemon-reload && systemctl enable --now twopic`. Порт 8787 наружу не открывай.
7. **HTTPS** (обязательно).
   - **Если уже есть домен и веб-сервер:** добавь маршрут `https://<домен>/2pic/` → `http://127.0.0.1:8787`. Префикс можно не срезать: сервер понимает любые пути, оканчивающиеся на `/v1/ingest` и `/v1/health`. Ограничь тело запроса 4 МБ и передавай `X-Forwarded-For`. Существующие сайты не трогай.
   - **Если домена нет:** поставь Caddy и используй бесплатное имя `<IP через дефисы>.sslip.io` (для IP 203.0.113.5 это `203-0-113-5.sslip.io`). Caddy сам получит сертификат Let's Encrypt. Блок для Caddyfile (если Caddy уже обслуживает другие сайты — добавь, а не заменяй):
     ```
     203-0-113-5.sslip.io {
         handle /2pic/* {
             request_body {
                 max_size 4MB
             }
             reverse_proxy 127.0.0.1:8787
         }
     }
     ```
   - Если файрвол включён, открой 80 (нужен для сертификата) и 443.
8. **Команда для отчёта.** Создай `/usr/local/bin/2pic-report` (755):
   ```
   #!/bin/sh
   exec sudo -u twopic env TWOPIC_DB=/var/lib/twopic/twopic.db python3 /opt/twopic/twopic_server.py report "$@"
   ```
   `2pic-report --days 30` покажет установки, ошибки (одинаковые вместе) и статистику использования.
9. **Резервная копия** (если на сервере уже есть система бэкапов — просто добавь в неё `/var/lib/twopic`; если нет — пропусти и скажи мне).
10. **Проверки.** Выполни все и покажи мне вывод. `<АДРЕС>` — итоговый адрес вида `https://203-0-113-5.sslip.io/2pic`, `$KEY` — ключ из шага 4.
    - `systemctl status twopic --no-pager` — служба работает.
    - `sudo -u twopic sh -c 'set -a; . /etc/twopic.env; set +a; python3 /opt/twopic/twopic_server.py selfcheck'` — в Telegram придёт «✅ Сервер 2pic: уведомления работают».
    - `curl -s <АДРЕС>/v1/health` → `{"ok": true, ...}` (по https, сертификат валиден, без `-k`).
    - `curl -s -o /dev/null -w '%{http_code}\n' -X POST <АДРЕС>/v1/ingest -H 'Authorization: Bearer wrong' -d '{}'` → `401`.
    - Тестовое событие и тестовая ошибка с правильным ключом:
      ```
      curl -s -X POST <АДРЕС>/v1/ingest -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d '{"schema":1,"install":"server-check","app":{"version":"check","build":"server"},"system":{"model":"server"},"sent_at":"2026-01-01T00:00:00Z","events":[{"id":"check-test-1","kind":"test","time":"2026-01-01T00:00:00Z"},{"id":"check-error-1","kind":"error","level":"ERROR","category":"check","message":"Проверочная ошибка: если она пришла в бот, всё работает","time":"2026-01-01T00:00:00Z","context":["2026-01-01 00:00:00.000 INFO  [check] строка журнала перед ошибкой"]}]}'
      ```
      Ответ `{"ok": true, "accepted": 2, "duplicates": 0}`. Секунд через 15 в боте должны появиться «✅ 2pic на связи» и «🔴 Ошибка в 2pic [check]».
    - Тот же запрос ещё раз → `"accepted": 0, "duplicates": 2` (повторы не сохраняются).
    - `2pic-report` показывает установку `server-check` и проверочную ошибку.
    - `journalctl -u twopic -n 30 --no-pager` — без ошибок, ключа в журнале нет.
11. **Итог мне одним сообщением:**
    - **Адрес** для поля «Адрес» в настройках 2pic (например `https://203-0-113-5.sslip.io/2pic`).
    - **Ключ** для поля «Ключ».
    - Результаты проверок из шага 10.
    - Где лежит база, как посмотреть отчёт (`2pic-report`), как перезапустить (`systemctl restart twopic`) и как сменить ключ: новый `TWOPIC_TOKEN` в `/etc/twopic.env`, `systemctl restart twopic`, потом новый ключ в настройках 2pic.

## Код: /opt/twopic/twopic_server.py
```python
__CODE__```
'''

prompt = TEMPLATE.replace("__SHA__", digest).replace("__CODE__", code if code.endswith("\n") else code + "\n")
out = os.path.join(HERE, "DEPLOY_PROMPT.md")
open(out, "w", encoding="utf-8").write(prompt)
print(f"wrote {out}: {len(prompt)} characters, server sha256 {digest}")
