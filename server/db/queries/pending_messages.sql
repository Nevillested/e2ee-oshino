-- name: SavePendingMessage :exec
INSERT INTO pending_messages (to_device_id, ciphertext)
VALUES ($1, $2);

-- name: GetPendingMessages :many
SELECT * FROM pending_messages WHERE to_device_id = $1 ORDER BY created_at;

-- name: DeletePendingMessages :exec
DELETE FROM pending_messages WHERE to_device_id = $1;

-- name: DeletePendingMessage :exec
DELETE FROM pending_messages WHERE id = $1;

-- name: DeleteOldPendingMessages :exec
DELETE FROM pending_messages WHERE created_at < $1;