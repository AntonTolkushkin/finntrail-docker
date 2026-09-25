# Быстрая синхронизация red.finntrail.ru → finntrail.ru

Скрипт полностью заменяет Docker-копию `finntrail.ru` данными локального
`red.finntrail.ru`. Доступность `finntrail.ru` во время операции не
сохраняется: контейнеры `nginx`, `php` и `cron` останавливаются до завершения.
Сам `red.finntrail.ru` скрипт не останавливает.

## Обычный запуск

На production-сервере:

```bash
cd /srv/finntrail/prod/env-docker
git pull --ff-only
sudo ./scripts/sync-red-to-prod.sh
```

Это единственная команда, которая нужна для штатной полной синхронизации.
Подтверждение не запрашивается: содержимое Docker-сайта и его база считаются
копией, а `red.finntrail.ru` — источником истины.

## Что делает команда

1. Запускает Percona и Redis, затем останавливает Docker `nginx/php/cron`.
2. Синхронизирует код с удалением файлов, которых больше нет на
   `red.finntrail.ru`.
3. Синхронизирует `upload` с тем же правилом удаления.
4. Создаёт свежий согласованный дамп локальной базы `redfinntrail`.
5. Полностью пересоздаёт базу Docker и импортирует дамп в Percona.
6. Очищает файловый кеш, Redis-кеш и старые PHP-сессии.
7. Запускает `php`, `nginx`, а затем `cron`.

Дамп и журналы сохраняются в:

```text
/srv/bitrix-prod/backups/red-to-prod/YYYYMMDDTHHMMSSZ/
```

## Что намеренно не копируется

Из `upload` сохраняются текущие файлы Docker-сайта:

- `upload/catalog_files/`;
- `upload/catalog.xml`;
- `upload/tmp/`.

Также не заменяются Docker-настройки Bitrix:

- `bitrix/.settings.php`;
- `bitrix/.settings_extra.php`;
- `bitrix/php_interface/dbconn.php`;
- `bitrix/php_interface/after_connect.php`;
- `bitrix/php_interface/after_connect_d7.php`.

Это сохраняет подключение к сервисам `mysql` и `redis`, настройки cookie,
Redis-сессий и совместимость с Percona 8.

## Почему перенос БД выполняется быстро

В исходной базе ещё есть таблицы `utf8mb3`. Скрипт меняет charset только в
`CREATE TABLE` внутри дампа до импорта. Данные `INSERT` не редактируются. Это
сохраняет исходные размеры `text/mediumtext` и не требует после импорта
перестраивать более тысячи таблиц командой `CONVERT TO CHARACTER SET`.

После импорта автоматически применяются четыре уже подтверждённые поправки
структуры Bitrix:

- `b_sale_order.SUM_PAID`;
- `b_sale_viewed_product.PRICE`;
- `b_iblock_element_property.ID`;
- полный первичный ключ `b_mail_domain_email(LOGIN, DOMAIN)`.

## Отдельный запуск частей

Только файлы:

```bash
sudo ./scripts/compose.sh stop cron nginx php
sudo ./scripts/sync-red-files.sh
sudo ./scripts/compose.sh up -d --wait php nginx cron
```

Только база:

```bash
sudo ./scripts/compose.sh stop cron nginx php
sudo ./scripts/sync-red-db.sh
sudo ./scripts/compose.sh up -d --wait php nginx cron
```

При отдельном запуске кеши автоматически не очищаются. Для обычной работы
используйте полный `sync-red-to-prod.sh`.

## Параметры источника

Значения по умолчанию соответствуют текущему серверу:

```text
RED_SYNC_SOURCE_ROOT=/var/www/red.finntrail.ru/public_html
RED_SYNC_SOURCE_DB=redfinntrail
RED_SYNC_EXPECTED_DEST_ROOT=/srv/bitrix-prod/www/public_html
```

Root на текущем сервере подключается к локальной MariaDB через Unix socket.
Если позже понадобится отдельный логин, создайте закрытый файл клиента и
передайте его так:

```bash
sudo env \
  RED_SYNC_DB_DEFAULTS_FILE=/root/redfinntrail-client.cnf \
  ./scripts/sync-red-to-prod.sh
```

## Если синхронизация прервалась

При ошибке скрипт оставляет Docker `nginx/php/cron` остановленными и сохраняет
сообщение об ошибке в `sync.log`. Исправьте причину и просто повторите полную
команду. Исходный `red.finntrail.ru` при этом не изменяется.

Минимальная проверка после успешного завершения:

```bash
./scripts/compose.sh ps -a
curl -I -H 'Host: finntrail.ru' http://127.0.0.1:8588/
```

Так как `red.finntrail.ru` продолжает принимать изменения во время дампа и
`rsync`, это быстрая, но не транзакционная копия файлов и БД. Для абсолютно
точного финального среза на несколько минут запретите изменения на источнике и
запустите ту же команду ещё раз.
