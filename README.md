# TG Cloud

Cloud backup for photos & videos using your own Telegram bot.

1. Create a bot with @BotFather, paste the token in the app.
2. Send `/start` to the bot, tap **Detect** to save the chat ID (or use a channel where the bot is admin).
3. Use **Backup now** or enable **Auto backup** (new media only, runs in background).

Notes: files go as documents (original quality); Bot API limit is 50 MB per file.
The Android project is generated in CI (`flutter create`) and patched by `tool/patch_manifest.py`.
