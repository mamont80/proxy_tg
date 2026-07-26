# proxy_tg / mishaserver.ru

Nginx + certbot reverse proxy для mishaserver.ru. Конфиг живёт в этом репо и деплоится через git pull прямо на сервере (без CI/CD).

## Топология

- **Сервер**: Vultr, IP `70.34.220.231`, пользователь `root`. Репозиторий на сервере лежит в `/my/nginx/proxy_tg`.
- **Доступ**: SSH-ключ `C:\mamont\github-key-nopass\private.ppk` (формат PuTTY .ppk, без пароля). Штатный `ssh`/OpenSSH его не читает напрямую — конвертация puttygen через CLI на этой машине не работает (даже с флагами `-O private-openssh` открывается GUI и подключение виснет). Рабочий способ — подключаться через `plink.exe` (PuTTY) напрямую с .ppk:
  ```
  "/c/Program Files/PuTTY/plink.exe" -ssh -batch -i "C:\mamont\github-key-nopass\private.ppk" root@70.34.220.231 "команда"
  ```
  Флаг `-batch` обязателен, иначе plink может задать интерактивный вопрос (например про host key) и зависнуть.
- **docker compose** сервисы: `mishaserver-nginx` (nginx:1.27-alpine) и `mishaserver-certbot`.
- Прокси-маршруты (nginx/conf.d/mishaserver.conf):
  - `mishaserver.ru`, `www.`, `max.` → backend `217.25.219.93:80` (внешний сервис, не наш — не чинить, если недоступен).
  - `web.mishaserver.ru` → `host.docker.internal:8442` (локальный сервис на самом сервере, тоже сторонний относительно nginx-репо).
  - `t.mishaserver.ru` → `https://api.telegram.org` (прокси для Telegram Bot API).

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

**Важно**: сам Bot API на `api.telegram.org` разрешает боту загружать файлы не больше 50 МБ (и скачивать до 20 МБ). Снятые здесь лимиты нужны, чтобы прокси не резал запрос раньше Telegram; чтобы реально заливать до 2 ГБ, нужен self-hosted [Local Bot API Server](https://core.telegram.org/bots/api#using-a-local-bot-api-server), и тогда `proxy_pass` в блоке `t.mishaserver.ru` надо переключить на него.

## Ловушка "git pull на сервере не проходит"

Если pull ругается `Your local changes to the following files would be overwritten by merge` — значит на сервере в рабочем дереве есть расхождение (по содержимому ИЛИ просто по правам доступа/исполняемому биту) с версией, закоммиченной в git. Частый случай — кто-то сделал `chmod +x` на сервере, а в git файл — обычный (0644); тогда diff показывает "0 insertions/deletions" но `mode change`.

**Не делать**: слепой rollback/reset без просмотра diff — именно так возник этот инцидент.

**Правильно**:
1. `git status --short` — что именно конфликтует.
2. `git diff <файл>` — посмотреть, реальные это правки или просто смена прав.
3. Если это ожидаемые локальные правки (например, сгенерированные certbot артефакты) — либо занести их в `.gitignore`, либо закоммитить.
4. Если это шум (например, только смена mode-бита) — `git checkout -- <файл>` и затем `git pull` спокойно проходит.

`certbot/conf/live/`, `certbot/conf/archive/`, `certbot/conf/renewal/`, `certbot/conf/ssl-dhparams.pem`, `certbot/conf/accounts/`, `nginx/logs/` — генерируются на сервере (сертификаты, логи), в git не должны попадать. Сейчас не в `.gitignore` — стоит туда добавить, чтобы `git status` не шумел и они случайно не попали в коммит.
