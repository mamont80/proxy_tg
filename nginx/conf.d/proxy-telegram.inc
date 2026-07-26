# Общие настройки проксирования на api.telegram.org.
# Файл намеренно с расширением .inc, а не .conf — иначе nginx подхватил бы его
# сам через `include /etc/nginx/conf.d/*.conf` вне server-блока.

proxy_pass https://api.telegram.org;
proxy_http_version 1.1;

proxy_ssl_server_name on;
proxy_ssl_name api.telegram.org;

proxy_set_header Host api.telegram.org;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;

# Таймауты рассчитаны на многоминутную передачу больших файлов.
# Это таймауты между двумя последовательными операциями чтения/записи,
# а не на весь запрос, поэтому долгая заливка их не превысит.
proxy_connect_timeout 30s;
proxy_send_timeout    300s;
proxy_read_timeout    300s;
