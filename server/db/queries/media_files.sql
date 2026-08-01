-- name: SaveMediaFile :one
INSERT INTO media_files (uploaded_by_account_id, recipient_account_id, object_key, size_bytes)
VALUES ($1, $2, $3, $4)
RETURNING *;

-- name: GetMediaFile :one
SELECT * FROM media_files WHERE id = $1;

-- name: DeleteMediaFile :exec
DELETE FROM media_files WHERE id = $1;