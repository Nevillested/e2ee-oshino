-- name: CreateDevice :one
INSERT INTO devices (account_id, identity_pubkey, device_name, identity_dh_pubkey, identity_dh_signature)
VALUES ($1, $2, $3, $4, $5)
RETURNING *;

-- name: GetDevicesByAccount :many
SELECT * FROM devices WHERE account_id = $1;

-- name: UpdateDeviceLastSeen :exec
UPDATE devices SET last_seen = now() WHERE id = $1;

-- name: GetLoginByDeviceID :one
SELECT a.id AS account_id, a.login, a.display_name
FROM devices d
JOIN accounts a ON a.id = d.account_id
WHERE d.id = $1;

-- name: DeleteDevicesByAccount :exec
DELETE FROM devices WHERE account_id = $1;

-- name: GetDeviceLastSeen :one
SELECT last_seen FROM devices WHERE id = $1;