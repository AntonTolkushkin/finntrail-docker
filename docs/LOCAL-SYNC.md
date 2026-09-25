# Production → local: WSL и macOS

`scripts/sync-server-to-local.sh` получает актуальную базу и файлы
`finntrail.ru` с production-сервера, полностью заменяет локальную базу и
запускает сайт на `https://finntrail.local`.

Скрипт намеренно работает только в WSL и macOS. Обычный Linux и production
отсекаются, чтобы команду нельзя было случайно запустить на сервере.

## Что происходит

1. При первом запуске создаётся локальный `.env` и сертификат `mkcert`.
2. Проверяется закреплённый ED25519 fingerprint сервера.
3. SSH запрашивает пароль пользователя один раз. Ключи SSH для этой операции
   намеренно отключены.
4. На сервере создаётся свежий транзакционный SQL dump в
   `/srv/finntrail/prod/env-docker/backups/local-sync/`.
5. Dump и сайт копируются через `rsync` с возможностью продолжить оборванную
   передачу.
6. Локальная база удаляется, создаётся заново и восстанавливается из dump.
7. `.settings.php`, Redis и legacy `dbconn.php` переводятся на локальные
   значения из `.env`; кеши очищаются.
8. Запускаются `mysql`, `redis`, `php`, `nginx`. Контейнер `cron` остаётся
   остановленным, чтобы локальная копия не выполняла production-агенты.

Копирование идёт с `--delete-after`: локальные файлы, которых нет на сервере,
будут удалены. Не храните незакоммиченные изменения внутри `www/public_html`.

## Требования

- Docker Desktop / Docker Engine с Compose v2;
- `rsync`, `ssh`, `ssh-keyscan`, `ssh-keygen`, `gzip`;
- пользователь сервера состоит в группе Docker, читает document root и может
  писать в `env-docker/backups/`;
- на сервере доступен путь `/srv/finntrail/prod/env-docker`;
- SSH-сервер разрешает password или keyboard-interactive authentication.

WSL (Ubuntu/Debian):

```bash
sudo apt update
sudo apt install -y rsync openssh-client gzip
```

macOS:

```bash
brew install rsync mkcert
```

Встроенный старый `rsync` macOS тоже поддерживается, но Homebrew-версия лучше
показывает общий прогресс.

## Запуск

Быстрый вариант — код и база, существующий локальный `upload/` не меняется:

```bash
./scripts/sync-server-to-local.sh
```

Полная синхронизация media-файлов:

```bash
./scripts/sync-server-to-local.sh --with-upload
```

Каталоги `upload/catalog_files/`, `upload/catalog.xml`, `upload/resize_cache/`
и временные файлы не копируются даже с `--with-upload`. Первичная передача
остального `upload/` может занимать десятки гигабайт; повторные запуски rsync
передают только изменения.

Без подтверждения (например, из локального Makefile):

```bash
./scripts/sync-server-to-local.sh --with-upload --yes
```

Другой SSH-пользователь:

```bash
./scripts/sync-server-to-local.sh --user root
```

Или через переменные:

```bash
export FINNTRAIL_SYNC_USER=finntraildeploy
export FINNTRAIL_SYNC_HOST=217.114.11.188
./scripts/sync-server-to-local.sh
```

## Fingerprint сервера

По умолчанию закреплён текущий ED25519 fingerprint:

```text
SHA256:DYfuONj+srGjzTaBq9uW07ccYHD0swtBeQLWeOb1DhA
```

При штатной замене host key сначала проверьте новый fingerprint по независимому
каналу, затем задайте его локально:

```bash
export FINNTRAIL_SYNC_HOST_FINGERPRINT='SHA256:НОВОЕ_ЗНАЧЕНИЕ'
```

Не отключайте эту проверку: при password authentication она защищает пароль и
production dump от отправки постороннему серверу.

## Что остаётся локальным

Не переносятся `.git`, `.env`, production-константы
`local/php_interface/include/constants.php`, кеши, резервные копии конфигов и
generated media. Если проект требует локальный `constants.php`, он создаётся из
`constants.example.php`, когда такого файла ещё нет.

После синхронизации, но до старта сайта, автоматически запускается локальный
`scripts/hooks/post-sync-local.sh`, если он существует и имеет executable bit.
Скопируйте пример и добавьте проектные отключения SMTP, платежей, CRM и webhook:

```bash
cp scripts/hooks/post-sync-local.sh.example \
   scripts/hooks/post-sync-local.sh
chmod +x scripts/hooks/post-sync-local.sh
```

Production SQL содержит реальные персональные и коммерческие данные. Храните
`backups/local-sync` только на зашифрованной рабочей машине и не передавайте его
третьим лицам.

## Повторный запуск после ошибки

Скрипт не удаляет уже скачанный snapshot, но при новом запуске создаёт свежий.
Исправьте причину и запустите ту же команду повторно. `cron` локально в любом
случае остаётся остановленным.
