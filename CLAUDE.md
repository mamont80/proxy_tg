# proxy_tg / mishaserver.ru

Nginx + certbot reverse proxy для mishaserver.ru. Конфиг живёт в этом репо и деплоится через git pull прямо на сервере (без CI/CD).

## Топология

- **Сервер**: Vultr, IP `70.34.220.231`, пользователь `root`. Репозиторий на сервере лежит в `/my/nginx/proxy_tg`.
- **Доступ**: SSH-ключ `C:\mamont\github-key-nopass\private.ppk` (формат PuTTY .ppk, без пароля). Штатный `ssh`/OpenSSH его не читает напрямую — конвертация puttygen через CLI на этой машине не работает (даже с флагами `-O private-openssh` открывается GUI и подключение виснет). Рабочий способ — подключаться через `plink.exe` (PuTTY) напрямую с .ppk:
  ```
  "/c/Program Files/PuTTY/plink.exe" -ssh -batch -i "C:\mamont\github-key-nopass\private.ppk" root@70.34.220.231 "команда"
  ```
  Флаг `-batch` обязателен, иначе plink может задать интерактивный вопрос (например про host key) и зависнуть.
- **docker compose** сервисы: `mishaserver-nginx` (nginx:1.27-alpine), `mishaserver-certbot`, `mishaserver-tg-bot-api` (Local Bot API Server) и `mishaserver-tg-files-cleaner`.
- Прокси-маршруты (nginx/conf.d/mishaserver.conf):
  - `mishaserver.ru`, `www.`, `max.` → backend `217.25.219.93:80` (внешний сервис, не наш — не чинить, если недоступен).
  - `web.mishaserver.ru` → `host.docker.internal:8442` (локальный сервис на самом сервере, тоже сторонний относительно nginx-репо).
  - `t.mishaserver.ru` → сервис `telegram-bot-api:8081` (свой Bot API Server), см. раздел ниже.
- **Потребитель прокси**: бот `syncmax` (отдельный репозиторий, `/my/bot/sync_max_tg`, .NET, режим Webhook) ходит в Telegram через `Telegram__ApiBaseUrl=https://t.mishaserver.ru`. Правок в боте переключение на свой Bot API Server не потребовало.

## Инцидент 2026-07-25 и что было исправлено

**Причина**: при `git pull` на сервере конфликтовал локально изменённый/новый файл, который git не мог перезаписать (см. "Ловушка pull" ниже). Пользователь не разобрался и откатил изменения вслепую, что оставило сервер в частично сломанном состоянии.

**Что реально сломалось**:
1. `certbot/conf/options-ssl-nginx.conf` и `certbot/conf/ssl-dhparams.pem` содержали буквальный текст `404: Not Found` — потому что `init-letsencrypt.sh` скачивал их через `curl -s` с GitHub raw URL, которые к этому моменту стали отдавать 404 (certbot реорганизовал репозиторий), а `curl -s` не проверяет HTTP-код и молча пишет тело ошибки в файл.
2. Из-за битого `options-ssl-nginx.conf` (он подключается через `include` в каждый https server-блок) nginx не мог распарсить конфиг и был в вечном `Restarting`.
3. Дополнительно на сервере оказались полностью утеряны файлы сертификата `mishaserver.ru` (`certbot/conf/live|archive|renewal`) — остался только `t.mishaserver.ru`.

**Исправлено**:
- Файлы `options-ssl-nginx.conf` восстановлен из git; `ssl-dhparams.pem` сгенерирован заново локально (`openssl dhparam -out ... 2048` через `certbot`-контейнер).
- Сертификат для `mishaserver.ru`+`www`+`web`+`max` перевыпущен заново через временный self-signed → webroot ACME challenge (та же схема, что в `init-letsencrypt.sh`).
- `init-letsencrypt.sh` переписан: больше не скачивает `options-ssl-nginx.conf`/`ssl-dhparams.pem` с GitHub (URL нестабильны), а требует, чтобы первый файл был в репозитории, второй — генерирует локально через openssl.
- `init-letsencrypt.sh` помечен в git как исполняемый (`chmod +x` в дереве), чтобы `git pull` больше не конфликтовал из-за локального `chmod +x` на сервере.

## Большие загрузки через t.mishaserver.ru

`client_max_body_size` для `t.mishaserver.ru` поднят до 2 ГБ (по умолчанию в nginx — 1 МБ, остальные домены так и остались на дефолте). Тело запроса не держится в памяти: `client_body_buffer_size 256k`, всё сверх этого nginx спулит во временный файл `/var/cache/nginx/client_temp` внутри контейнера (это тот же раздел `/dev/vda2`, где живёт всё остальное). На сервере ~950 МБ RAM и ~9 ГБ свободного диска, поэтому:

- две `limit_conn`-зоны (`tg_big_ip`, `tg_big_all`) ограничивают 2 больших загрузки с одного IP и 3 суммарно — в пике это ~6 ГБ временных файлов;
- «большой» запрос определяется через `map $content_length` (>= 10 МБ, т.е. 8+ цифр). Ключ с пустым значением в `limit_conn` не учитывается, поэтому обычные вызовы Bot API и долгий `getUpdates` под лимит не попадают;
- запрос с `Transfer-Encoding: chunked` (без `Content-Length`) под `limit_conn` не попадёт — его ограничивает только `client_max_body_size`. Штатные клиенты Bot API отправляют `Content-Length`;
- если свободное место на диске изменится, тюнить надо числа в `limit_conn` в `nginx/conf.d/mishaserver.conf`.

`location /file/` (скачивание файлов) вынесен отдельно: там `proxy_buffering off` и `proxy_max_temp_file_size 0`, чтобы большой ответ шёл клиенту потоком, а не складывался на диск.

Общие `proxy_*`-директивы для обоих location вынесены в `nginx/conf.d/proxy-telegram.inc`. Расширение `.inc`, а не `.conf`, — намеренно: `nginx.conf` делает `include /etc/nginx/conf.d/*.conf`, и файл с `.conf` был бы подхвачен вне `server`-блока и сломал бы конфиг.

## Local Bot API Server

`t.mishaserver.ru` проксируется не на `api.telegram.org`, а на собственный [Bot API Server](https://core.telegram.org/bots/api#using-a-local-bot-api-server) (сервис `telegram-bot-api`, образ `aiogram/telegram-bot-api`). Публичный сервер режет загрузку на 50 МБ, свой — поднимает до 2000 МБ.

**Что именно даёт флаг `--local`** (проверено по исходникам `tdlib/telegram-bot-api`, файл `telegram-bot-api/Client.cpp`, а не по документации — она этого не разделяет):

- **Загрузка (upload)**: лимита на размер в коде сервера нет вообще. 50 МБ — ограничение конкретно публичного `api.telegram.org`, любой self-hosted сервер его снимает, `--local` для этого не нужен.
- **Скачивание (download)**: `Client.cpp:9369` — `if (!parameters_->local_mode_ && ... > MAX_DOWNLOAD_FILE_SIZE)`, где `MAX_DOWNLOAD_FILE_SIZE = 20 << 20`. Потолок 20 МБ снимается **только** флагом `--local`.
- **Побочный эффект `--local`**: `Client.cpp:17817` — `getFile` начинает возвращать в `file_path` абсолютный путь на диске (`/var/lib/telegram-bot-api/<токен>/videos/file_5.mp4`) вместо относительного.

Из-за последнего пункта в конфиге nginx есть regex-location, который ловит `/file/bot<токен>/var/lib/telegram-bot-api/...` и отдаёт файл прямо с диска через `alias` (каталог примонтирован в nginx на чтение). Клиентские библиотеки строят URL как `{base}/file/bot{token}/{file_path}`, получается двойной слэш — nginx схлопывает его сам, `merge_slashes` включён по умолчанию. Благодаря этому бота править не пришлось. Рядом оставлен обычный проксирующий `location /file/` на случай запуска без `--local` (regex приоритетнее префикса, так что он не перекрыт).

**Секреты**: `api_id`/`api_hash` с https://my.telegram.org лежат в `.env` рядом с `docker-compose.yml` (в git не попадает, шаблон — `.env.example`). Это учётные данные приложения, а не бота: с токеном бота не связаны, одной пары хватает на всех ботов сервера. Без них контейнер падает на старте с `error: environment variable TELEGRAM_API_ID is required`.

**Диск — главный риск.** Свободно ~9 ГБ при размере файла до 2 ГБ. Меры:

- `proxy_request_buffering off` в `location /`: nginx стримит тело в бэкенд, а не пишет свою копию во временный файл. Бэкенд локальный, защищать его от медленного клиента смысла нет, а лишние 2 ГБ на диск — есть.
- `limit_conn` ограничивает 2 одновременные большие передачи.
- Bot API Server **сам ничего не удаляет** — принятые и скачанные файлы копятся, пока не кончится диск. Сервис `tg-files-cleaner` раз в 10 минут удаляет медиа старше часа. Чистит только внутри известных подкаталогов (`photos`, `videos`, `documents`, …), чтобы не задеть базу бота в корне `<token>/`; незнакомый подкаталог просто не будет чиститься — безопасный вид отказа.

Порт `8081` наружу не публикуется, доступ только через nginx. Статистика: `docker exec mishaserver-tg-bot-api wget -qO- http://localhost:8082`.

**Если бот вдруг перестанет видеть файлы**, проверять в первую очередь: права на `telegram-bot-api/data` (nginx-воркер работает под пользователем `nginx` и должен иметь доступ на чтение к каталогам, которые создаёт `telegram-bot-api`) и логи `docker logs mishaserver-tg-bot-api`.

## Ловушка "git pull на сервере не проходит"

Если pull ругается `Your local changes to the following files would be overwritten by merge` — значит на сервере в рабочем дереве есть расхождение (по содержимому ИЛИ просто по правам доступа/исполняемому биту) с версией, закоммиченной в git. Частый случай — кто-то сделал `chmod +x` на сервере, а в git файл — обычный (0644); тогда diff показывает "0 insertions/deletions" но `mode change`.

**Не делать**: слепой rollback/reset без просмотра diff — именно так возник этот инцидент.

**Правильно**:
1. `git status --short` — что именно конфликтует.
2. `git diff <файл>` — посмотреть, реальные это правки или просто смена прав.
3. Если это ожидаемые локальные правки (например, сгенерированные certbot артефакты) — либо занести их в `.gitignore`, либо закоммитить.
4. Если это шум (например, только смена mode-бита) — `git checkout -- <файл>` и затем `git pull` спокойно проходит.

`certbot/conf/live/`, `certbot/conf/archive/`, `certbot/conf/renewal/`, `certbot/conf/ssl-dhparams.pem`, `certbot/conf/accounts/`, `nginx/logs/` — генерируются на сервере (сертификаты, логи), в git не должны попадать. Сейчас не в `.gitignore` — стоит туда добавить, чтобы `git status` не шумел и они случайно не попали в коммит.
