# XWiki с Let's Encrypt на Docker Compose

Скопируйте файл `.env.exmaple`

```
cp .env.exmaple .env
```

❗ Измените переменные в файле `.env` в соответствии с вашими требованиями.

Есть два варианта развёртывания: **с Traefik и HTTPS** (файл `xwiki-traefik-letsencrypt-docker-compose.yml`) и **без Traefik** (файл `docker-compose.yml`), см. ниже. Сейчас используется вариант запуска без Traefik, так как отключен HTTPS

## Вариант с Traefik и Let's Encrypt

Файл `.env` должен находиться в той же директории, что и compose-файл.

Перед развёртыванием создайте сети для сервисов командами:

```
docker network create traefik-network
```

```
docker network create xwiki-network
```

Развёртывание XWiki с помощью Docker Compose:

```
docker compose -f xwiki-traefik-letsencrypt-docker-compose.yml -p xwiki up -d
```

## Файл docker-compose.yml — запуск без Traefik

`docker-compose.yml` — **дополнительный** compose-файл для запуска XWiki **без Traefik**. Подходит для локальной разработки, тестирования или когда обратный прокси и HTTPS не нужны.

**Отличия от варианта с Traefik:**
- Нет сервиса Traefik и интеграции с Let's Encrypt.
- XWiki доступен напрямую по порту **8080** на хосте (`http://localhost:8080` или `http://<IP>:8080`).
- Требуется только сеть `xwiki-network` (сеть `traefik-network` не используется).

**Сервисы в составе:** PostgreSQL, XWiki, контейнер резервного копирования (`backups`) — те же, что и в полном варианте; переменные из `.env` используются так же.

Перед запуском создайте сеть (если ещё не создана):

```
docker network create xwiki-network
```

Запуск (запускать можно без указания файла и проекта, в команде для примера):

```
docker compose up -d
```

Запуск с явно указаным файлом и проектом
```
docker compose -f docker-compose.yml -p xwiki up -d
```

Остановка:

Если запускали с файлами и проектом по умолчанию
```
docker compose down
```

Если запускали с явно указаными файлом и проектом 
```
docker compose -f docker-compose.yml -p xwiki down
```

💡 Файл `.env` должен лежать в той же директории, что и `docker-compose.yml`.

### Логи XWiki при запуске без Traefik

- **Где хранятся логи**: логи Tomcat/XWiki внутри контейнера пишутся в каталог `/usr/local/tomcat/logs`.
- **Проброс логов в том**: в `docker-compose.yml` добавлен именованный том `xwiki-logs`, который монтируется в контейнер XWiki по пути `/usr/local/tomcat/logs`. Пример фрагмента:

  ```yaml
  volumes:
    xwiki-data:
    xwiki-postgres:
    xwiki-backups:
    xwiki-logs:

  services:
    xwiki:
      image: ${XWIKI_IMAGE_TAG}
      volumes:
        - xwiki-data:${DATA_PATH}
        - xwiki-logs:/usr/local/tomcat/logs
  ```

- **Что это даёт**:
  - логи **переживают перезапуск контейнера** и не обнуляются при `docker compose down/up`;
  - том `xwiki-logs` можно подключить к любому вспомогательному контейнеру (например, `alpine`) и просматривать/архивировать файлы логов даже при неработающем XWiki.

Посмотреть содержимое тома с логами можно, например, так:

```bash
docker run --rm -v xwiki-logs:/logs alpine ls -R /logs
```

## Резервное копирование

Резервное копирование выполняет отдельный контейнер `backups`. Образ собирается из `docker/backups` на базе `XWIKI_POSTGRES_IMAGE_TAG` (тот же major PostgreSQL, что и у сервера): в нём есть `pg_dump`, `gzip`, `tar`, `find`, Python и `boto3` для выгрузки в S3. Тег образа задаётся переменной `XWIKI_BACKUP_IMAGE_TAG` (по умолчанию `xwiki-backup:15`).

Перед первым запуском или после изменения `docker/backups` соберите образ:

```bash
docker compose build backups
```

### Как создаются бэкапы внутри контейнера

После старта контейнер ждёт **задержку** `BACKUP_INIT_SLEEP` (например, 30 минут), чтобы PostgreSQL и XWiki успели полностью подняться. Затем в бесконечном цикле по очереди выполняется:

1. **Создание единого архива** (`$XWIKI_BACKUP_NAME-ГГГГ-ММ-ДД_ЧЧ-ММ.tar.gz`)
   - Временный каталог: `pg_dump` → `postgres.sql.gz`, `tar` данных XWiki → `application-data.tar.gz`.
   - Оба файла упаковываются в один bundle-архив в `XWIKI_BACKUPS_PATH`.
   - Если шаг с БД или данными не удался, bundle **не создаётся** (цикл пропускается).

2. **Выгрузка в S3** (если в `.env` задан `S3_BUCKET_NAME`)
   - `scripts/xwiki_backup_to_s3.py upload` отправляет bundle-архивы в бакет (один объект = БД + данные).
   - Префикс ключей: `S3_PREFIX` (по умолчанию `xwiki/backups`).

3. **Очистка старых бэкапов**
   - Удаляются bundle-архивы старше `BACKUP_PRUNE_DAYS` дней.

4. **Пауза до следующего цикла**
   - `sleep $BACKUP_INTERVAL` (например, 24h).

Бэкапы хранятся в томе `xwiki-backups` (путь в контейнере — `XWIKI_BACKUPS_PATH`). В S3 каждый объект — тот же bundle-файл.

**Содержимое bundle:**

| Файл внутри архива | Содержимое |
|--------------------|------------|
| `postgres.sql.gz` | Сжатый дамп PostgreSQL |
| `application-data.tar.gz` | Сжатый архив каталога `DATA_PATH` |

### Переменные окружения

| Переменная | Назначение |
|------------|------------|
| `BACKUP_INIT_SLEEP` | Задержка перед первым бэкапом (например, `30m`). |
| `BACKUP_INTERVAL` | Интервал между циклами бэкапа (например, `24h`). |
| `XWIKI_BACKUPS_PATH` | Каталог для bundle-архивов в контейнере `backups`. |
| `XWIKI_BACKUP_NAME` | Префикс имени bundle (например, `xwiki-backup`). |
| `BACKUP_PRUNE_DAYS` | Удалять bundle старше этого количества дней. |
| `DATA_PATH` | Путь к данным XWiki в контейнере (должен совпадать с тем, что монтируется в XWiki). |
| `XWIKI_BACKUP_IMAGE_TAG` | Тег собранного образа контейнера `backups`. |
| `S3_BUCKET_NAME` | Имя бакета; если пусто, выгрузка в S3 пропускается. |
| `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` | Учётные данные S3-совместимого хранилища. |
| `S3_REGION`, `S3_ENDPOINT_URL` | Регион и endpoint (для MinIO и аналогов). |
| `S3_PREFIX` | Префикс ключей bundle в бакете. |

Использование контейнера `backups` обеспечивает регулярное и автоматическое резервное копирование БД и данных приложения; расписание и срок хранения настраиваются через переменные окружения.

## Описание скрипта xwiki-logs.sh

Скрипт собирает и выводит логи XWiki из контейнера для диагностики и отладки, используется когда логи слишком большие для отображения в терминале:

1. **Логи контейнера**: выводит вывод `docker logs` за указанный период (`--since`) с ограничением по количеству строк (`--tail`). По умолчанию — за последний час, 500 строк.

2. **Хвосты лог-файлов в контейнере**: показывает последние строки из основных логов приложения:
   - `/usr/local/tomcat/logs/xwiki.log`
   - `/var/lib/xwiki/data/logs/xwiki.log`
   - `/usr/local/tomcat/logs/catalina.out`

3. **Поиск по паттерну**: выполняет `grep` по указанному регулярному выражению в этих же файлах (по умолчанию ищет: index, task, consumer, llm, mention, links, executor, timeout, rejected, error, exception).

4. **Архив логов**: создаёт сжатый архив логов в контейнере и копирует его на хост в текущую директорию (удобно прикладывать к тикету в поддержку).

**Параметры вызова** (все опциональны):
- `$1` — паттерн для grep (по умолчанию: `index|task|consumer|llm|mention|links|executor|timeout|rejected|error|exception`);
- `$2` — период для `docker logs --since` (по умолчанию: `1h`);
- `$3` — количество последних строк tail (по умолчанию: `500`).

**Переменные окружения**: `CONTAINER` — имя контейнера XWiki (по умолчанию: `xwiki-xwiki-1`).

Чтобы сделать скрипт `xwiki-logs.sh` исполняемым, выполните команду:

```
chmod +x xwiki-logs.sh
```

## Описание скрипта xwiki-restore.sh

Восстанавливает **единый bundle** (база данных и данные приложения из одного архива).

1. Показывает **нумерованный** список bundle на диске (`[local]`) и в S3 (`[s3]`), если настроен `S3_BUCKET_NAME`.
2. Вы вводите **номер** (не полное имя файла).
3. Для S3: скачивание в `XWIKI_BACKUPS_PATH`, затем restore; для local: сразу restore.
4. Подтверждение `y`, остановка XWiki, восстановление БД и файлов, запуск XWiki.

```bash
chmod +x xwiki-restore.sh
./xwiki-restore.sh

# или сразу с номером из меню:
./xwiki-restore.sh 3
```

Скрипты `xwiki-restore-database.sh` и `xwiki-restore-application-data.sh` устарели (раздельные бэкапы больше не создаются).