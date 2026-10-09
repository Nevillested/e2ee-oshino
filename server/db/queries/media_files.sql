-- name: SaveMediaFile :one
INSERT INTO media_files (uploaded_by_account_id, recipient_account_id, object_key, size_bytes)
VALUES ($1, $2, $3, $4)
RETURNING *;

-- докачка по кусочкам (upload_media_chunked.go): id объекта в MinIO выбирает
-- сам сервер ещё на шаге /init (до того, как файл целиком долетел), поэтому
-- здесь id передаётся явно, а не генерируется базой — строка в БД создаётся
-- только при успешном /complete, тот же id, что и ключ объекта в MinIO.
-- name: SaveMediaFileWithID :one
INSERT INTO media_files (id, uploaded_by_account_id, recipient_account_id, object_key, size_bytes)
VALUES ($1, $2, $3, $4, $5)
RETURNING *;

-- name: GetMediaFile :one
SELECT * FROM media_files WHERE id = $1;

-- name: DeleteMediaFile :exec
DELETE FROM media_files WHERE id = $1;
-- файл, принятый в горячий буфер на диске Москвы (media_staging.go) —
-- в MinIO его пока нет, туда его позже перенесёт архиватор.
-- name: SaveStagedMediaFile :one
INSERT INTO media_files (id, uploaded_by_account_id, recipient_account_id, object_key, size_bytes, storage)
VALUES ($1, $2, $3, $4, $5, 'local')
RETURNING *;

-- name: MarkMediaDelivered :exec
UPDATE media_files SET delivered_at = now() WHERE id = $1 AND delivered_at IS NULL;

-- кандидаты на перенос в архив: только то, что получатель уже скачал.
-- name: ListStagedMediaReadyForArchive :many
SELECT * FROM media_files
WHERE storage = 'local' AND delivered_at IS NOT NULL
ORDER BY created_at
LIMIT 50;

-- name: MarkMediaArchived :exec
UPDATE media_files SET storage = 'archive' WHERE id = $1;
