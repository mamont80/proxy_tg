# Общие настройки проксирования на Local Bot API Server (сервис telegram-bot-api
# из этого же docker compose). Наружу его порт не опубликован, ходим по
# внутренней сети compose.
#
# Файл намеренно с расширением .inc, а не .conf — иначе nginx подхватил бы его
# сам через `include /etc/nginx/conf.d/*.conf` вне server-блока.

# Адрес бэкенда задан переменной намеренно. С литеральным `proxy_pass
# http://telegram-bot-api:8081` nginx резолвит имя один раз при старте: если
# telegram-bot-api ещё не поднялся, nginx падает с "host not found in upstream",
# а после пересоздания контейнера продолжает стучаться на устаревший IP.
# Через переменную + встроенный DNS docker (127.0.0.11) имя перечитывается.
resolver 127.0.0.11 valid=30s ipv6=off;
set $tg_api_backend "telegram-bot-api:8081";
# при переменной в proxy_pass путь не подставляется автоматически — отсюда $request_uri
proxy_pass http://$tg_api_backend$request_uri;

proxy_http_version 1.1;

proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;

# Таймауты рассчитаны на многоминутную передачу больших файлов.
# Это таймауты между двумя последовательными операциями чтения/записи,
# а не на весь запрос, поэтому долгая заливка их не превысит.
proxy_connect_timeout 30s;
proxy_send_timeout    300s;
proxy_read_timeout    300s;
