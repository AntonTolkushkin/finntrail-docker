# Перенос существующего Bitrix-сайта

Ниже — последовательность переноса существующего Bitrix-сайта в текущий
Docker-стек. Источник может работать на MariaDB 10.11, а контейнер использует
Percona Server 8.0. Перенос между ними выполняется только SQL dump/restore.

## 1. Инвентаризация старого сервера

До копирования зафиксируйте:

- версии PHP и MySQL/MariaDB;
- кодировку и collation БД;
- список cron-заданий и Bitrix-агентов;
- содержимое `bitrix/.settings.php`, `bitrix/php_interface/dbconn.php` и
  `local/php_interface` без публикации секретов;
- используется ли Sphinx, Push&Pull, Memcached, внешний SMTP и файловое
  хранилище;
- объем БД и каталогов `upload`, `bitrix`, `local`.

Если фактическая версия исходной БД отличается, сначала проверьте дамп на
development-окружении. Не переключайте трафик до полной проверки.

## 2. Подготовка нового сервера

```bash
./scripts/init-env.sh production
```

Отредактируйте `.env`, создайте каталоги из README и запустите только хранилища:

```bash
./scripts/compose.sh up -d mysql redis
./scripts/compose.sh ps
```

## 3. Первичное копирование файлов

Пример с нового сервера:

```bash
rsync -aHAX --numeric-ids --info=progress2 \
  old-server:/path/to/document-root/ /srv/bitrix-prod/www/public_html/
```

Не копируйте старые системные сокеты и временные кеши. После копирования:

```bash
sudo ./scripts/fix-permissions.sh
```

## 4. Дамп и импорт БД

На старом сервере для InnoDB:

```bash
mariadb-dump \
  --single-transaction \
  --quick \
  --routines \
  --triggers \
  --events \
  --hex-blob \
  --default-character-set=utf8mb4 \
  -u root -p bitrix | gzip -1 > bitrix.sql.gz
```

Перед импортом проверьте свободное место. На новом сервере:

```bash
./scripts/restore-db.sh /path/to/bitrix.sql.gz
```

## 5. Настройки приложения

Основное подключение в `bitrix/.settings.php` должно указывать контейнер
Percona Server (service name остаётся `mysql`):

```php
'host' => 'mysql',
'database' => 'bitrix',
'login' => 'bitrix',
'password' => 'значение MYSQL_PASSWORD из .env',
```

Пароль нельзя читать из Docker `.env` автоматически, если существующий проект
не реализует это сам. На первом этапе внесите его в защищенный конфигурационный
файл Bitrix и не добавляйте этот файл в публичные репозитории.

Для кеша Bitrix возможна конфигурация Redis такого вида; точное расположение
зависит от версии ядра и уже существующего `.settings.php`:

```php
'cache' => [
    'value' => [
        'type' => 'redis',
        'redis' => [
            'host' => 'redis',
            'port' => 6379,
            'password' => 'значение REDIS_PASSWORD из .env',
            'database' => 0,
        ],
    ],
],
```

PHP-сессии используют Redis database `1`, поэтому кешу оставлена database `0`.
Перед изменением объедините блок с текущей конфигурацией, а не заменяйте весь
`.settings.php`.

## 6. Проверка без DNS

Поднимите весь production-стек:

```bash
./scripts/deploy.sh
```

Проверяйте loopback-порт с корректным Host:

```bash
curl -I -H 'Host: finntrail.ru' http://127.0.0.1:8588/
./scripts/compose.sh ps
./scripts/compose.sh logs --tail=200 nginx php mysql
```

До изменения внешнего host-Nginx проверяйте контейнер на loopback. Затем
переключите только virtual host Finntrail на proxy из `deploy/host-nginx` и
проверьте:

- публичную часть и личный кабинет;
- авторизацию и сохранение сессии;
- оформление и оплату тестового заказа;
- обмены, webhooks, почту и фоновые задания;
- загрузку файлов и генерацию изображений;
- административную «Проверку системы» Bitrix;
- отсутствие смешанного HTTP/HTTPS и корректный реальный IP посетителя.

## 7. Финальное переключение

1. Заранее уменьшите TTL DNS.
2. Переведите старый сайт в режим обслуживания или остановите запись заказов.
3. Сделайте финальный `rsync` и свежий дамп БД.
4. Импортируйте финальный дамп.
5. Запустите стек и выполните smoke-тест через `127.0.0.1:8588`.
6. Переключите Finntrail virtual host в host-Nginx на Docker upstream.
7. Сохраните старый сервер без записи до окончания периода наблюдения.

Не выполняйте одновременно перенос, обновление ядра Bitrix, смену СУБД и
массовый рефакторинг приложения: эти изменения лучше разделить, чтобы
причина возможной ошибки оставалась понятной.
