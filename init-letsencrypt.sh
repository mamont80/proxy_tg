#!/usr/bin/env bash
set -e

if ! command -v docker &> /dev/null; then
  echo "Docker не найден. Установите docker и docker compose plugin." >&2
  exit 1
fi

# Группы доменов: каждая группа получает свой сертификат.
# Имя первого домена в группе используется как имя папки /etc/letsencrypt/live/<name>/
GROUP_MAIN=(mishaserver.ru www.mishaserver.ru web.mishaserver.ru max.mishaserver.ru)
GROUP_TG=(t.mishaserver.ru)

RSA_KEY_SIZE=4096
DATA_PATH="./certbot"
EMAIL=""          # укажите свой email для уведомлений Let's Encrypt, например admin@mishaserver.ru
STAGING=0         # поставьте 1 для тестового прогона (staging), чтобы не упереться в rate limit

if [ -d "$DATA_PATH/conf/live" ]; then
  read -p "Найдены существующие сертификаты в $DATA_PATH. Перевыпустить? (y/N) " decision
  if [ "$decision" != "Y" ] && [ "$decision" != "y" ]; then
    exit
  fi
fi

mkdir -p "$DATA_PATH/conf"

if [ ! -e "$DATA_PATH/conf/options-ssl-nginx.conf" ]; then
  echo "### options-ssl-nginx.conf не найден. Файл должен идти в репозитории (certbot/conf/options-ssl-nginx.conf) — проверьте git." >&2
  exit 1
fi

if [ ! -e "$DATA_PATH/conf/ssl-dhparams.pem" ]; then
  echo "### Генерирую ssl-dhparams.pem локально (не скачиваю — путь certbot на GitHub периодически меняется и ломает curl) ..."
  docker compose run --rm --entrypoint "openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048" certbot
  echo
fi

issue_group() {
  local domains=("$@")
  local primary="${domains[0]}"
  local domain_args=""
  for d in "${domains[@]}"; do
    domain_args="$domain_args -d $d"
  done

  echo "### Создаю временный самоподписанный сертификат для $primary ..."
  mkdir -p "$DATA_PATH/conf/live/$primary"
  docker compose run --rm --entrypoint "\
    openssl req -x509 -nodes -newkey rsa:$RSA_KEY_SIZE -days 1 \
      -keyout '/etc/letsencrypt/live/$primary/privkey.pem' \
      -out '/etc/letsencrypt/live/$primary/fullchain.pem' \
      -subj '/CN=localhost'" certbot
  echo
}

issue_group "${GROUP_MAIN[@]}"
issue_group "${GROUP_TG[@]}"

echo "### Запускаю nginx ..."
docker compose up --force-recreate -d nginx
echo

request_real_cert() {
  local domains=("$@")
  local primary="${domains[0]}"
  local domain_args=""
  for d in "${domains[@]}"; do
    domain_args="$domain_args -d $d"
  done

  echo "### Удаляю временный сертификат для $primary ..."
  docker compose run --rm --entrypoint "\
    rm -Rf /etc/letsencrypt/live/$primary && \
    rm -Rf /etc/letsencrypt/archive/$primary && \
    rm -Rf /etc/letsencrypt/renewal/$primary.conf" certbot
  echo

  local email_arg
  if [ -z "$EMAIL" ]; then
    email_arg="--register-unsafely-without-email"
  else
    email_arg="--email $EMAIL"
  fi

  local staging_arg=""
  if [ "$STAGING" != "0" ]; then
    staging_arg="--staging"
  fi

  echo "### Запрашиваю сертификат Let's Encrypt для $primary ..."
  docker compose run --rm --entrypoint "\
    certbot certonly --webroot -w /var/www/certbot \
      $staging_arg \
      $email_arg \
      $domain_args \
      --rsa-key-size $RSA_KEY_SIZE \
      --agree-tos \
      --force-renewal" certbot
  echo
}

request_real_cert "${GROUP_MAIN[@]}"
request_real_cert "${GROUP_TG[@]}"

echo "### Перезагружаю nginx с боевыми сертификатами ..."
docker compose exec nginx nginx -s reload

echo "### Запускаю certbot для автопродления ..."
docker compose up -d certbot

echo "Готово."
