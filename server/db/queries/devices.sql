-- name: CreateDevice :one
INSERT INTO devices (account_id, identity_pubkey, device_name)
VALUES ($1, $2, $3)
RETURNING *;

-- name: GetDevicesByAccount :many
SELECT * FROM devices WHERE account_id = $1;

-- name: UpdateDeviceLastSeen :exec
UPDATE devices SET last_seen = now() WHERE id = $1;