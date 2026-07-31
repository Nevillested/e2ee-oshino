-- name: SavePendingMessage :exec
INSERT INTO pending_messages (to_device_id, ciphertext)
VALUES ($1, $2);

-- name: GetPendingMessages :many
SELECT * FROM pending_messages WHERE to_device_id = $1 ORDER BY created_at;

-- name: DeletePendingMessages :exec
DELETE FROM pending_messages WHERE to_device_id = $1;