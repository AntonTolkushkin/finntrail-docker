# Редиректы и блокировка IP на production-сервере

Инструкция рассчитана на Debian 12 без FASTPANEL и на уже установленный UFW.
Production работает по схеме:

`Интернет → host Nginx :80/:443 → 127.0.0.1:8588 → Docker Nginx → PHP`

Host Nginx управляет TLS и редиректами. UFW блокирует IP до обработки запроса
Nginx. Docker публикует application-порт только на loopback, поэтому правила
UFW не конфликтуют с опубликованными наружу Docker-портами.

## Перед установкой

Проверьте UFW и публичные порты:

```bash
sudo ufw status verbose
sudo ss -lntp | grep -E ':(22|80|443|8588)\b'
docker ps --format 'table {{.Names}}\t{{.Ports}}'
```

Ожидаемая схема:

- UFW активен;
- входящие `22/tcp`, `80/tcp`, `443/tcp` разрешены;
- host Nginx слушает публичный IP на `80/443`;
- Docker Nginx опубликован только как `127.0.0.1:8588->80/tcp`;
- MySQL, Redis и PHP-FPM не опубликованы наружу.

Если нужных правил ещё нет, сначала не закрывая текущую SSH-сессию добавьте:

```bash
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
sudo ufw status verbose
```

Не выполняйте `nft flush ruleset`: UFW и Docker используют nftables backend и
свои служебные цепочки.

## Установка host edge

Из production-клона:

```bash
cd /srv/finntrail/prod/env-docker
sudo ./scripts/install-host-edge.sh
```

Установщик:

- требует уже активный UFW;
- размещает `edge-redirect` и `edge-ip` в `/usr/local/sbin`;
- создаёт постоянные реестры в `/var/lib/finntrail-edge`;
- подключает map-файлы редиректов к host Nginx;
- восстанавливает IP-блокировки как UFW rules;
- удаляет только старую таблицу `inet finntrail_edge`, если она осталась от
  прежней версии скрипта;
- включает минутный systemd timer для временных блокировок.

Установщик не перезапускает Docker и не меняет базовые политики UFW.

## Host Nginx без панели

Пример конфигурации:

`deploy/host-nginx/finntrail-docker.conf.example`

Установка обычного Debian virtual host:

```bash
sudo install -m 0644 \
  deploy/host-nginx/finntrail-docker.conf.example \
  /etc/nginx/sites-available/finntrail-docker.conf

sudo ln -sfn \
  /etc/nginx/sites-available/finntrail-docker.conf \
  /etc/nginx/sites-enabled/finntrail-docker.conf

sudo nginx -t
sudo systemctl reload nginx
```

Перед reload проверьте IP, пути сертификата и отсутствие второго virtual host с
тем же `server_name`. Найти дубликаты можно командой:

```bash
sudo nginx -T 2>&1 | grep -nE 'server_name .*finntrail\.ru'
```

В `http`-контексте должна загружаться конфигурация:

```nginx
/etc/nginx/conf.d/00-finntrail-edge-maps.conf
```

В обоих production-блоках `server` для HTTP и HTTPS должна быть строка:

```nginx
include /etc/nginx/finntrail-rules/redirect-server.conf;
```

Для WebSocket map должен использовать именно `$http_upgrade`:

```nginx
map $http_upgrade $finntrail_connection_upgrade {
    default upgrade;
    '' close;
}
```

## Управление редиректами

Добавить постоянный редирект:

```bash
sudo edge-redirect add 301 /old/path /new/path
```

Добавить временный редирект:

```bash
sudo edge-redirect add 302 /campaign https://example.com/landing
```

Посмотреть список:

```bash
sudo edge-redirect list
```

Удалить:

```bash
sudo edge-redirect delete /old/path
```

Скрипт сначала выполняет `nginx -t`, затем reload. При ошибке файлы правил
возвращаются в предыдущее состояние. Сопоставление выполняется по
нормализованному `$uri`; query string не участвует в поиске правила.

## Управление IP-блокировками через UFW

Заблокировать IP навсегда:

```bash
sudo edge-ip ban 203.0.113.10
```

Заблокировать на время:

```bash
sudo edge-ip ban 203.0.113.10 2h
sudo edge-ip ban 2001:db8::10 7d
```

Поддерживаются суффиксы `s`, `m`, `h`, `d`, `w`. CIDR-подсети намеренно не
принимаются: команда управляет отдельными IPv4/IPv6-адресами.

Посмотреть список:

```bash
sudo edge-ip list
sudo ufw status numbered
```

Разблокировать:

```bash
sudo edge-ip unban 203.0.113.10
```

Удалить все IP-блокировки, созданные этим инструментом:

```bash
sudo edge-ip clear
```

Правило блокирует только входящий TCP к портам `80,443`, имеет комментарий
`finntrail-edge` и не затрагивает SSH. Постоянные правила сохраняет UFW. Сроки
временных правил хранятся в реестре и проверяются раз в минуту systemd timer.

Проверка таймера:

```bash
sudo systemctl status finntrail-edge-ip-expire.timer
sudo systemctl list-timers finntrail-edge-ip-expire.timer
```

## Хранение и журнал

Файлы состояния:

- `/var/lib/finntrail-edge/redirects.tsv`;
- `/var/lib/finntrail-edge/blocked-ips.tsv`;
- `/etc/nginx/finntrail-rules/redirects-301.map`;
- `/etc/nginx/finntrail-rules/redirects-302.map`.

Журнал действий:

```bash
sudo tail -f /var/log/finntrail-edge/actions.log
```

После изменения репозитория повторный запуск установщика безопасно обновляет
скрипты и systemd units:

```bash
cd /srv/finntrail/prod/env-docker
sudo ./scripts/install-host-edge.sh
```

## Аварийное отключение

Редиректы:

```bash
sudo truncate -s 0 /var/lib/finntrail-edge/redirects.tsv
sudo edge-redirect apply
```

IP-блокировки Finntrail:

```bash
sudo edge-ip clear
sudo systemctl disable --now finntrail-edge-ip-expire.timer
```

Это не отключает UFW и не удаляет его остальные правила.
