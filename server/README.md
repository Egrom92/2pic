# 2pic server

Receives errors and usage statistics from 2pic, stores them in SQLite, and sends new errors to a Telegram bot. Python 3.9+, standard library only.

- `twopic_server.py`: the server (`serve`, `report`, `selfcheck`). Settings come from environment variables; see the top of the file.
- `DEPLOY_PROMPT.md`: step-by-step instructions for an AI assistant on the server, with the server code and its checksum embedded. Paste the whole file into the assistant's chat.
- `make_deploy_prompt.py`: rebuilds `DEPLOY_PROMPT.md` after `twopic_server.py` changes.
- `test_server.py`: end-to-end check that starts a real server and a fake Telegram. `--app .build/debug/TwoPic` also makes the real app send to that server.

```bash
python3 server/test_server.py
swift build && python3 server/test_server.py --app .build/debug/TwoPic
```
