# slack-user-token

Агент пише в Slack **від твого імені** звичайним HTTP-запитом з user token: надсилає, редагує
вже надіслане, вантажить файли. Без MCP, без моделі посередині, один запит — ~200 мс.

## Навіщо, якщо є Slack MCP

MCP-конектор теж пише від тебе, але через модель: повільно, а в headless-запусках (`claude -p`,
cron, launchd) інколи просто не піднімається. Токен працює з будь-якого скрипта. І він вміє те,
чого MCP не вміє: `chat.update` — редагувати вже надіслане повідомлення, і завантажувати файли в
тред.

## Що за «апка» треба створити

Це **твоя особиста Slack app** у воркспейсі — просто контейнер, який видає тобі user token.
Ніякого бота, сервера чи коду в ній нема, ставиш її тільки на себе. Все, що вона робить, —
дозволяє скриптам ходити в Slack API від твого імені з тими правами (scopes), які ти їй дав.

## Як отримати токен (один раз, у браузері)

1. [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From scratch**.
   Назва будь-яка, воркспейс — свій.
2. **OAuth & Permissions** → **User Token Scopes** — саме *User*, не *Bot*: бот не бачить твої
   DM і пише не від тебе. Мінімум для цього скрипта:

   | scope | для чого |
   |---|---|
   | `chat:write` | `--post`, `--update` |
   | `files:write` | `--upload` |

   Хочеш, щоб агент ще й читав — додай `search:read`, `channels:history`, `groups:history`,
   `im:history`, `mpim:history`, `users:read`.
3. Там же **Install to Workspace** → Allow. Якщо воркспейс вимагає апруву адміна, запит піде
   адміну — це єдиний крок, який від тебе не залежить.
4. Скопіюй **User OAuth Token** — він починається з `xoxp` (не `xoxb`).
5. Поклади в Keychain, щоб токен не валявся по файлах:
   ```bash
   security add-generic-password -s slack-user-token -a "$USER" -w 'xoxp…' -U
   ```
6. Перевір:
   ```bash
   ./slack-token.py --check     # хто ти, який воркспейс, які scopes реально видані
   ```

Треба ще scope — додаєш на тій же сторінці, **Reinstall to Workspace**, і знову крок 5.

## Користування

```bash
./slack-token.py --post   --channel C0123 --file msg.md                  # в канал
./slack-token.py --post   --channel U0123 --file msg.md                  # в DM людині (id людини)
./slack-token.py --post   --channel C0123 --thread 1726.0001 --file msg.md   # в тред
./slack-token.py --update --channel C0123 --ts 1726.0001 --file msg.md   # замінити текст
./slack-token.py --upload --channel C0123 --thread 1726.0001 --file report.pdf
./slack-token.py --post   --channel C0123 --file msg.md --plate "_Sent with <@U0BOT>_"
```

Текст — звичайний Markdown (`**bold**`, `[text](url)`, `` `code` ``). Друкує permalink.
Коди виходу: `0` ок · `1` Slack відмовив · `2` аргументи / нема токена · `3` не вистачає scope.

Скрипт — python3 без залежностей. Агенту він не обовʼязковий: скажи Claude «шли через Slack API
токеном з Keychain `slack-user-token`», і запит він складе сам. Скрипт просто прибирає ці
здогадки і має вже перевірені граблі (нижче).

## Граблі, які ми вже зібрали

- **Не став mention бота в тексті повідомлення.** `<@Claude>` в тілі — і Slack пропонує
  додати його в розмову. Той самий mention в `context`-блоці (`--plate`) — нормальна сіра
  плашка під текстом, без цього діалогу.
- **`chat.update` через токен в UI не показує «(edited)»** — принаймні в наших тестах. В API
  поле `edited` є, людям його не видно. Тобто можна живо оновлювати повідомлення (прогрес,
  секундомір), і воно не буде помічене як відредаговане.
- **Ліміт на редагування** — Tier 3, ~50 `chat.update` на хвилину. Раз на ~1.2 с у нас
  відпрацювало 8.5 хвилин поспіль (427 правок) без жодного `ratelimited`.
- **`markdown_text` не можна поєднати з `blocks`.** Тому з плашкою текст іде двома блоками,
  `markdown` і `context` — скрипт це робить сам.
