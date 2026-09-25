# Cron в production-контейнере

Production использует BusyBox `crond`. Каталог с расписанием и заданиями
подключен к контейнеру `cron` как read-only bind mount:

- `confs/cron` -> `/opt/project-cron`.

После первоначального применения конфигурации новый образ собирать и
контейнер пересоздавать не требуется. Изменения файлов на хосте видны в
контейнере. Фоновая синхронизация проверяет их каждые 30 секунд и устанавливает
root-owned crontab в writable-каталог BusyBox. На применение изменения следует
отводить до двух минут.

## Добавление профиля Acrit ExportProPlus

Для частых изменений используйте helper:

```bash
./scripts/cron-acrit.sh add 1 '7 * * * *'
./scripts/cron-acrit.sh add 2 '*/30 * * * *'
./scripts/cron-acrit.sh add 3 '25 2 * * *'
./scripts/cron-acrit.sh list
./scripts/cron-acrit.sh remove 2
```

Повторный `add` для существующего ID заменяет его прежнее расписание.

Либо откройте `confs/cron/crontabs/root` и добавьте строку вручную:

```cron
7 * * * * /opt/project-cron/jobs/acrit-export 1
```

Здесь `1` — ID профиля. Другие примеры:

```cron
# Каждые 30 минут
*/30 * * * * /opt/project-cron/jobs/acrit-export 2

# Ежедневно в 02:25
25 2 * * * /opt/project-cron/jobs/acrit-export 3

# По будням в 04:40
40 4 * * 1-5 /opt/project-cron/jobs/acrit-export 4
```

В пользовательском crontab BusyBox нет колонки пользователя: после пяти
полей расписания сразу указывается команда. Экспортер самостоятельно запускает
PHP от пользователя `bitrix`.

У каждого профиля отдельный lock и лог:

```text
/opt/www/public_html/upload/acrit.exportproplus/log/cron-profile-ID.log
```

Не планируйте разные тяжелые профили на одну минуту. Разносите их по времени,
так как каждый профиль может запускать несколько PHP-процессов.

## Добавление произвольной задачи

Скопируйте шаблон:

```bash
cp confs/cron/jobs/example-bitrix-task.disabled \
   confs/cron/jobs/my-task
chmod 755 confs/cron/jobs/my-task
```

Укажите в новом файле PHP-скрипт и лог. Затем добавьте расписание в
`confs/cron/crontabs/root`:

```cron
15 3 * * * /opt/project-cron/jobs/my-task
```

Для shell-задачи создайте такой же исполняемый файл в `confs/cron/jobs`, но
поместите в него нужную shell-команду. Пароли и токены нельзя записывать в
crontab или коммитить в Git.

## Проверка

Показать загруженное расписание:

```bash
./scripts/compose.sh exec -T cron \
  crontab -c /opt/project-cron/crontabs -u root -l
```

Проверить файлы:

```bash
./scripts/compose.sh exec -T cron sh -lc '
set -eu
test -x /opt/project-cron/jobs/acrit-export
sh -n /opt/project-cron/jobs/acrit-export
crontab -c /opt/project-cron/crontabs -u root -l
'
```

Вручную запустить реальную выгрузку профиля 1:

```bash
./scripts/compose.sh exec -T cron \
  /opt/project-cron/jobs/acrit-export 1
```

Посмотреть служебные сообщения:

```bash
./scripts/compose.sh logs --since=15m cron
```

Если изменение требуется применить немедленно, сначала убедитесь, что в
контейнере нет выполняющихся заданий. Принудительно синхронизировать файл без
перезапуска контейнера можно командой:

```bash
./scripts/compose.sh exec -T cron /opt/project-cron/cron-sync
```

После этого BusyBox применит обновление на ближайшем минутном цикле. Обычные
изменения следует оставить для фоновой синхронизации, чтобы не прерывать уже
запущенную выгрузку.
