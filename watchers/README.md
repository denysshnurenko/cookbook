# watchers — демони, які самі кажуть агенту, що робити

Шість автоматичних watcher-ів мого харнеса, які не клод-сесії, а звичайні python-процеси: раз
на кілька хвилин опитують джерело, порівнюють із кешем і, коли є подія, друкують **один рядок
промпту в ту agterm-сесію, яка веде цю роботу**. Я нічого не прошу, вони знають самі.

Тут — патерн, умови кожного watcher-а і один робочий приклад (`watch-lane.py`) із двома
lane-ами, яким потрібен лише `gh`.

## Патерн

```
poll (gh / GraphQL трекера / Slack API, секунди, без моделі)
  → json-кеш (status/…-cache.json)
  → знайти сесію: назва або cwd містить гілку чи її worktree-slug (`feat/dt123-x` ↔ `feat-dt123-x`)
  → три gates: claude у foreground · агент не mid-turn · поле вводу порожнє
  → bracketed paste + ОКРЕМИЙ Return після паузи
  → прочитати поле назад: наш текст ще там = не пішло, спробуємо наступного разу
  → stamp-файл на подію: один раз, ніколи двічі
```

Три речі, які коштували мені найбільше, поки я до них дійшов:

- **Промпт набирається одним bracketed paste** (`ESC[200~ … ESC[201~`), а Return іде окремим
  записом після 0.6 с. Набраний посимвольно промпт обганяє свій Return і відправляється
  фрагментом (731 символ з 1744, один раз).
- **«Порожнє поле» треба перевіряти пробою**: Claude Code малює свою підказку прямо в полі
  вводу, і `session text` повертає її як набраний текст. Набрати пробіл, прочитати, стерти:
  підказка зникає, людський текст лишається.
- **`session type` пише в ліву панель, `session text` читає видиму**. Читати треба ту, куди
  пишеш (`--pane left`), інакше при відкритому split-і watcher читає не той екран і вічно бачить
  «щось набрано».

## Шість lane-ів

| lane | джерело | умова | що друкує в сесію | dedupe |
|---|---|---|---|---|
| `autofix` | статус тікета в трекері (GraphQL, раз на 10 хв) | мій тікет перейшов у `Fix Needed` | «пофіксь: <коментар QA>», далі сам процес до `Ready for Testing` | stamp `<тікет>.<статус>` |
| `deliver_questions` | інбокс трекера (`notifications`, mention/comment) + Slack-згадки | мене тегнули, і після цього я не відповів | «на відповідь чекає X у <тред>, склади чернетку» | stamp `<тікет>.<createdAt>` |
| `deliver_changes` | опис + коментарі тікета, під який є жива сесія | hash опису змінився або зʼявився чужий коментар | «у тікеті нові зміни (<що>), перечитай» | baseline на тікет |
| `deliver_pr_events` | `gh search prs --author=@me` + `gh pr view` | колега зробив approve / changes requested / коментар після мого останнього ходу | «на PR #N X запросив зміни: «…». Виведи список зауважень з оцінкою, нічого не виправляй, поки я не вирішу» | stamp `pr.<repo>.<N>.<at>` |
| `deliver_merge_gate` | `gh pr list` + трекер | gate 1 у трекері `READY_FOR_STAGE` · approve reviewer-а або label `no-human-review` · label `self-reviewed` · зелені checks · MERGEABLE | «PR #N пройшов merge gate, запусти deliver, не питай» | stamp `merge.<repo>.<N>.<head sha>` |
| `deliver_done` | статус тікета | тікет у Done/Cancelled, а сесія ще сидить у worktree | «зупини процеси, перевір unpushed, відкрий teardown overlay» | stamp `done.<тікет>.<worktree>` |

Слово «мердж» більше не gate: коли чотири умови зелені, PR летить сам. Tooling-PR (усі файли
під `validation/`, `.claude/`, `docs/`) не потребує жодного review: watcher ставить
`no-human-review` і вмикає GitHub auto-merge.

Запити до трекера, якщо у вас той самий DOTT (персональний токен з Edit Profile → MCP tokens
працює і для `/graphql`):

```graphql
query($n: Int!) { issueByNumber(number: $n) {
  project { name } status { name category }
  validations { branch { verdict } } } }        # gate 1: READY_FOR_STAGE

query($limit: Int!, $page: Int!, $filter: NotificationsFilter) {
  notifications(limit: $limit, page: $page, filter: $filter) {
    items { id type group referenceId isRead createdAt metaJson } } }   # інбокс = watermark
```

## Приклад: `watch-lane.py`

Два lane-и на чистому `gh` + `agtermctl`: `pr_events` і `merge_gate`. Python 3.9, stdlib.

```bash
export WATCH_REPOS=owner/repo            # через кому, якщо кілька
export WATCH_GH_LOGIN=<твій GitHub login>
export WATCH_REVIEWER=<login колеги>     # чий approve рахується; порожньо = всі requested reviewers
export WATCH_BOTS=<bot-login>            # логіни, які ніколи не «колега» (лінк-бот трекера)
export WATCH_GATE_CMD='my-gate.sh "$PR" "$BRANCH"'   # опційно: exit 0 = трекер дозволяє

python3 watch-lane.py --once --dry-run   # що б надрукував, нічого не друкує
python3 watch-lane.py --once             # один прохід
python3 watch-lane.py &                  # демон, раз на 5 хв (WATCH_TICK)
```

Умови `merge_gate` у прикладі: approve від `WATCH_REVIEWER` (або від усіх requested reviewers,
або label `no-human-review`), жодного standing `CHANGES_REQUESTED`, label `self-reviewed`, усі
checks зелені, `MERGEABLE`, і `WATCH_GATE_CMD` повернув 0, якщо заданий. Gate 1 з трекера сюди не
зашитий саме через `WATCH_GATE_CMD`: у кожного свій трекер.

Label-и треба створити в репо (`gh label create self-reviewed`, `gh label create no-human-review`).
`self-reviewed` ставить агент після того, як ти глянув diff: GitHub не дає автору approve-нути
свій PR, тож label і є запис.

Що приклад НЕ робить: не вміє в Slack і трекер (описано вище, код у мене привʼязаний до наших
токенів), не ставить label-и сам, бачить лише сесії frontmost-вікна agterm (`agtermctl tree`).
