# Перенос в `AntonTolkushkin/finntrail-docker`

Цель — получить самостоятельный репозиторий, а не новый GitHub fork, и не
перенести secrets, dump, сайт или устаревшие исходники базового проекта.

## Что удаляет подготовка

Из подготовленного дерева исключены:

- `docs/COMMIT_TO_FORK.md`;
- одноразовый `docker-compose.percona-migration.yml`;
- 688 МБ неиспользуемых upstream `sources/`;
- неиспользуемые `confs/php82/`, `confs/php83/`, `confs/php85/`,
  `confs/redis/`, `confs/sphinx/` и `confs/mariadb/`.

Рабочие `confs/php84/`, `confs/php/`, `confs/percona/`, `confs/nginx/` и
`confs/cron/` сохранены. `LICENSE` также сохранён: он относится к унаследованным
GPL-компонентам и не превращает новый GitHub repository в технический fork.

Если изменения устанавливались компактным patch-файлом, удалите бинарный
upstream payload отдельной командой:

```bash
./scripts/cleanup-fork-payload.sh --apply
```

Команда удаляет только перечисленные выше пути. До создания коммита все они
восстанавливаются обычным `git restore`.

## 1. Зафиксировать подготовку

В текущем checkout:

```bash
git add -A
git diff --cached --check
git commit -m "Prepare standalone Finntrail Docker repository"
./scripts/publish-independent-repository.sh --check
```

Проверка не допускает tracked `.env`, dump, содержимое сайта, старый URL и
известные неиспользуемые каталоги.

## 2. Создать пустой репозиторий

На GitHub создайте `AntonTolkushkin/finntrail-docker` как **обычный пустой
repository**:

- не используйте кнопку Fork;
- не добавляйте README, `.gitignore` или license при создании;
- branch будет создан скриптом как `main`.

Если репозиторий уже находится в fork network, обычная смена remote этого не
исправляет. Его нужно удалить/переименовать и создать заново как пустой
репозиторий либо обращаться в GitHub Support.

## 3. Опубликовать независимую историю

Рекомендуемый вариант — один новый root commit без истории старого форка:

```bash
./scripts/publish-independent-repository.sh \
  --publish-clean-history
```

Скрипт создаёт commit через `git commit-tree`, отправляет его в `main` нового
пустого repository и **не переписывает текущий checkout**. Force push не
используется.

Если старая история действительно нужна:

```bash
./scripts/publish-independent-repository.sh \
  --publish-full-history
```

## 4. Проверить новый repository

```bash
cd ..
git clone git@github.com:AntonTolkushkin/finntrail-docker.git \
  finntrail-docker
cd finntrail-docker
git log --oneline --decorate -5
git remote -v
./scripts/publish-independent-repository.sh --check
```

Только после этой проверки меняйте remote в production checkout:

```bash
cd /srv/finntrail/prod/env-docker
git remote set-url origin \
  git@github.com:AntonTolkushkin/finntrail-docker.git
git remote -v
git fetch origin main
```

Не выполняйте `git reset --hard` на production ради переноса remote. Сначала
убедитесь, что текущий production commit присутствует в новом repository либо
что переход на новую независимую историю запланирован отдельным deploy.
