-- name: UpsertPushToken :exec
INSERT INTO push_tokens (device_id, fcm_token)
VALUES ($1, $2)
ON CONFLICT (device_id) DO UPDATE
SET fcm_token = EXCLUDED.fcm_token, updated_at = now();

-- name: GetPushTokenByDevice :one
SELECT * FROM push_tokens WHERE device_id = $1;

-- name: DeletePushTokenByDevice :exec
DELETE FROM push_tokens WHERE device_id = $1;
