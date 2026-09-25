# Finntrail Bitrix Docker environment

Один репозиторий поддерживает три изолированных режима:

| Режим | Домены | База | Внешний HTTPS |
|---|---|---|---|
| Local | `finntrail.local` | локальная Percona Server | `mkcert` внутри Docker |
| Production | `finntrail.ru`, `www.finntrail.ru` | отдельная production Percona Server | существующий host-Nginx либо Traefik |
| Development | `dev.finntrail.ru`, `dev1.finntrail.ru`, `dev2.finntrail.ru` | отдельная development Percona Server для всех трёх имён | существующий host-Nginx либо Traefik |

Production и development запускаются из разных клонов репозитория с разными
`.env`, `COMPOSE_PROJECT_NAME`, каталогами сайта и volumes.

## Состав

| Сервис | Образ по умолчанию | Назначение |
|---|---|---|
| `nginx` | `quay.io/bitrix24/nginx:1.30.4-v1-alpine` | статика и FastCGI |
| `php` / `cron` | `quay.io/bitrix24/php:8.4.25-fpm-v1-alpine` | PHP-FPM и агенты Bitrix |
| `mysql` | `quay.io/bitrix24/percona-server:8.0.46-v1-rhel` | Percona Server 8.0 |
| `redis` | `redis:8.2.9-alpine` | сессии и кеш |
| `composer` | PHP-образ, профиль `tools` | одноразовые команды Composer |
| `node` | `node:22.13.1-alpine`, профиль `tools` | одноразовые команды npm |
| `mailpit` | `axllent/mailpit:v1.30.7` | локальный перехват писем без внешней отправки |

Имя Compose-сервиса оставлено `mysql`, но внутри работает Percona Server 8.0.
Для БД используются отдельные volumes `percona_data` и `percona_log_data`.
Данные между разными СУБД переносятся только SQL dump/restore, без копирования
`/var/lib/mysql`.

---

# Local: WSL, Linux и macOS

Требования: Docker Compose 2.24.4+, минимум 4 GB RAM, свободные локальные порты
`80/443/8025`.

```bash
./scripts/init-env.sh local
./scripts/local-up.sh
```

В WSL скрипт запросит UAC Windows, установит локальный CA `mkcert`, создаст
сертификат и добавит `finntrail.local` в Windows hosts. На macOS используется
Homebrew/Keychain. После запуска откройте <https://finntrail.local>.

Локальные письма не отправляются во внешнюю сеть: `msmtp` передаёт их в
Mailpit. Интерфейс писем доступен на <http://127.0.0.1:8025/>.

Корневой сертификат `mkcert` автоматически копируется в отдельное локальное
хранилище доверия PHP. Сертификаты конкретного компьютера не добавляются в Git.

Windows PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\init-env.ps1 -Mode Local
powershell -ExecutionPolicy Bypass -File .\scripts\local-up.ps1
```

Повторное создание сертификата:

```bash
./scripts/setup-local-cert.sh
./scripts/compose.sh up -d --force-recreate nginx
```

Если предыдущий `init-env.sh local` завершился ошибкой сертификата, в старой
версии скрипта мог остаться `.env`. После обновления не удаляйте данные Docker:

```bash
./scripts/setup-local-cert.sh
ls -l confs/nginx/certs/finntrail.local/{fullchain.pem,privkey.pem}
./scripts/local-up.sh
```

Для полностью чистой повторной инициализации удалите только незакоммиченный
`.env`, затем снова выполните `./scripts/init-env.sh local`. Обновлённый скрипт
сам удаляет созданный `.env`, если настройка сертификата завершается ошибкой.

Файлы local находятся в `www/public_html`.

## Синхронизация production → local

На WSL или macOS можно одной командой получить свежую базу и файлы с
`217.114.11.188`, автоматически восстановить их в локальной Percona и запустить
`https://finntrail.local`:

```bash
./scripts/sync-server-to-local.sh
```

По умолчанию существующий локальный `upload/` не меняется. Полный перенос
медиафайлов запускается явно:

```bash
./scripts/sync-server-to-local.sh --with-upload
```

SSH запросит пароль один раз. Подробности, исключения и требования:
[docs/LOCAL-SYNC.md](docs/LOCAL-SYNC.md).

---

# Production на Debian с host-Nginx

## Существующие сайты на хосте

Контейнерный Nginx публикуется только на `127.0.0.1:8588`. Поэтому запуск
Compose не занимает публичные `80/443` и сам по себе не останавливает другие
сайты. Опасны только следующие действия:

- установка `NGINX_BIND_ADDRESS=0.0.0.0`;
- установка `HTTP_PORT=80` или `443` на уже занятом адресе;
- запуск Traefik на тех же `80/443`, которые слушает host-Nginx;
- одновременное включение старого и нового virtual host с одинаковым
  `server_name`.

Для текущего сервера оставьте `EDGE_MODE=host-nginx`. Хостовый Nginx принимает
HTTPS и проксирует только Finntrail в Docker. Остальные сайты продолжают
обслуживаться как раньше.

## Каталоги и установка

```bash
sudo install -d -o "$USER" -g "$USER" \
  /srv/bitrix-prod/env-docker \
  /srv/bitrix-prod/www/public_html \
  /srv/bitrix-prod/backups

git clone https://github.com/AntonTolkushkin/finntrail-docker.git \
  /srv/bitrix-prod/env-docker
cd /srv/bitrix-prod/env-docker
./scripts/init-env.sh production
```

Проверьте `.env`:

```dotenv
APP_ENV=production
COMPOSE_PROJECT_NAME=bitrix-prod
EDGE_MODE=host-nginx
NGINX_BIND_ADDRESS=127.0.0.1
HTTP_PORT=8588
WWW_PATH=/srv/bitrix-prod/www
BACKUP_PATH=/srv/bitrix-prod/backups
```

Разместите сайт в `/srv/bitrix-prod/www/public_html`, затем:

```bash
sudo ./scripts/fix-permissions.sh
./scripts/validate.sh production
./scripts/deploy.sh
curl -i -H 'Host: finntrail.ru' http://127.0.0.1:8588/docker-health
```

Для повторной полной синхронизации локального `red.finntrail.ru` в Docker
используйте `sudo ./scripts/sync-red-to-prod.sh`. Скрипт допускает простой
production во время переноса. Описание и исключения:
[docs/RED-TO-PROD-SYNC.md](docs/RED-TO-PROD-SYNC.md).

Пример host-Nginx находится в
`deploy/host-nginx/finntrail-docker.conf.example`. На Debian без панели
разместите virtual host в `/etc/nginx/sites-available`, включите его ссылкой в
`/etc/nginx/sites-enabled`, выпустите сертификат и затем выполните `nginx -t`
и reload. Не оставляйте одновременно два virtual host с одинаковым
`server_name`.

Управление production-редиректами и IP-блокировками отдельными командами
описано в [docs/HOST-EDGE-RULES.md](docs/HOST-EDGE-RULES.md).

## Traefik как альтернатива

Используйте только если Traefik уже является единственным владельцем публичных
`80/443` либо работает на другом IP:

```dotenv
EDGE_MODE=traefik
TRAEFIK_NETWORK=proxy
TRAEFIK_ROUTER_NAME=finntrail-prod
TRAEFIK_HOST_RULE='Host(`finntrail.ru`) || Host(`www.finntrail.ru`)'
```

---

# Development: dev, dev1 и dev2

## Установка

```bash
sudo install -d -o "$USER" -g "$USER" \
  /srv/bitrix-dev/env-docker \
  /srv/bitrix-dev/www \
  /srv/bitrix-dev/backups

git clone https://github.com/AntonTolkushkin/finntrail-docker.git \
  /srv/bitrix-dev/env-docker
cd /srv/bitrix-dev/env-docker
./scripts/init-env.sh development
./scripts/validate.sh development
./scripts/deploy.sh
```

Development занимает только `127.0.0.1:8589`. В `.env` должны остаться:

```dotenv
APP_ENV=development
COMPOSE_PROJECT_NAME=bitrix-dev
EDGE_MODE=host-nginx
NGINX_BIND_ADDRESS=127.0.0.1
HTTP_PORT=8589
WWW_PATH=/srv/bitrix-dev/www
MYSQL_DATABASE=bitrix_dev
```

`init-env.sh development`:

1. создаёт отдельные пароли Percona и Redis;
2. генерирует Basic Auth для всех dev-доменов;
3. создаёт каталоги `dev`, `dev1`, `dev2`;
4. создаёт в `dev1/dev2` симлинки `bitrix` и `upload` на основной `dev`.

Все три домена используют одну development-базу. Cron запускается только от
основного `/opt/www/dev/public_html`. Development ограничен по CPU, RAM и числу
PHP-FPM workers; лимиты можно изменить в `.env.development.example`.

Проверка маршрутизации до изменения DNS:

```bash
curl -i -H 'Host: dev.finntrail.ru' http://127.0.0.1:8589/docker-health
curl -I -u developer:ПАРОЛЬ_ИЗ_ENV \
  -H 'Host: dev1.finntrail.ru' http://127.0.0.1:8589/
```

Подробная схема: [docs/SERVER-TOPOLOGY.md](docs/SERVER-TOPOLOGY.md).

## Production → development

Из development-клона:

```bash
./scripts/sync-prod-to-dev.sh \
  --prod-root /srv/bitrix-prod/env-docker

./scripts/sync-prod-to-dev.sh \
  --prod-root /srv/bitrix-prod/env-docker \
  --with-upload
```

Скрипт не умеет синхронизировать dev обратно в production. Перед заменой он
создаёт rollback-dump development. Код следует обновлять через Git, БД — этим
скриптом, `upload` — флагом `--with-upload`.

Обязательно создайте собственный `scripts/hooks/post-sync-dev.sh`: после
production-дампа нужно отключить реальную почту, платежи, SMS, CRM и webhooks.
Шаблон находится в `scripts/hooks/post-sync-dev.sh.example`. Без исполняемого
hook синхронизация завершится до изменения dev-базы; небезопасный обход требует
явного флага `--allow-unsanitized`.

---

# Composer и npm

Composer уже находится в PHP-образе и использует тот же PHP/extensions, что и
сайт. Node/npm запускается отдельным одноразовым контейнером и не потребляет
ресурсы постоянно.

```bash
./scripts/composer.sh --version
./scripts/composer.sh install --no-dev --optimize-autoloader

./scripts/npm.sh --version
./scripts/npm.sh ci
./scripts/npm.sh run build
```

Команды выполняются от UID/GID `979:979`. Это предотвращает появление root-owned
`vendor` и `node_modules`. Если владелец файлов на сервере другой, измените
`TOOLS_UID` и `TOOLS_GID` в `.env`.

---

# Настройка производительности

Production-профиль содержит важные параметры текущего сервера:

- Percona buffer pool `10G`, `150` connections и `READ-COMMITTED`;
- PHP-FPM dynamic, до `60` workers по умолчанию;
- PHP `memory_limit=1024M`, upload/post до `1024M`;
- расширенный OPcache и Redis-сессии;
- rate limit только для выбранных роботов;
- slow query log от двух секунд.

`pm.max_children=100` из старого конфига не перенесён буквально: вместе с
`memory_limit=2048M` он способен исчерпать память сервера при пике. Начальное
значение `60` тоже нужно проверить по фактическому P95 RSS PHP-процесса:

```text
pm.max_children = доступная_память_для_PHP / P95_RSS_одного_worker
```

До переключения production выполните нагрузочный тест и наблюдайте OOM,
load average, очередь PHP-FPM, slow PHP log и Percona buffer pool.
Ни одна статическая конфигурация не может гарантировать пиковую
производительность без характеристик сервера и профиля запросов.

---

# Резервные копии и восстановление

Полная копия БД и файлов:

```bash
./scripts/backup.sh
```

Только согласованный дамп БД:

```bash
./scripts/backup-db.sh
```

Восстановление без удаления лишних таблиц:

```bash
./scripts/restore-db.sh /path/to/dump.sql.gz
```

Полная замена выбранной в `.env` базы:

```bash
./scripts/restore-db.sh --replace-database /path/to/dump.sql.gz
```

Никогда не подключайте старый volume MariaDB напрямую к Percona/MySQL 8.
Compose использует отдельные volumes `percona_data` и `percona_log_data`.
Для переноса создайте SQL dump исходной БД и импортируйте его через
`scripts/restore-db.sh`.

---

# Zabbix Agent 2

Zabbix Agent 2 устанавливается на хост и не добавляется в Compose. Контейнеры не
занимают `10050/10051`. Входящий `10050/tcp` разрешайте только IP Zabbix
server/proxy; `10051/tcp` нужен как исходящее направление для active checks.
Подробности: [docs/ZABBIX.md](docs/ZABBIX.md).

---

# Управление

```bash
./scripts/compose.sh ps
./scripts/compose.sh logs -f --tail=100 nginx php mysql
./scripts/compose.sh exec php php -v
./scripts/compose.sh stop
./scripts/compose.sh down
```

`down` сохраняет volumes. `down -v` удаляет Percona, Redis и остальные данные;
не выполняйте его на сервере без проверенной внешней резервной копии.

Подготовка независимого репозитория и перенос в
`AntonTolkushkin/finntrail-docker` описаны в
[docs/REPOSITORY-MOVE.md](docs/REPOSITORY-MOVE.md).

Секреты `.env`, Basic Auth, сертификаты, файлы сайта, дампы и архивы исключены
из Git.
