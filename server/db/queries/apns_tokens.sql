-- name: UpsertApnsTokens :exec
INSERT INTO apns_tokens (device_id, alert_token, voip_token, sandbox)
VALUES ($1, $2, $3, $4)
ON CONFLICT (device_id) DO UPDATE
SET alert_token = COALESCE(EXCLUDED.alert_token, apns_tokens.alert_token),
    voip_token = COALESCE(EXCLUDED.voip_token, apns_tokens.voip_token),
    sandbox = EXCLUDED.sandbox,
    updated_at = now();

-- name: DeleteApnsTokenDuplicates :exec
-- Тот же телефон под прежним device_id (переустановка без выхода) — снять,
-- иначе он получал бы пуши и старого аккаунта.
DELETE FROM apns_tokens
WHERE device_id <> sqlc.arg(device_id)
  AND (alert_token = sqlc.narg(alert_token) OR voip_token = sqlc.narg(voip_token));

-- name: GetApnsTokensByDevice :one
SELECT * FROM apns_tokens WHERE device_id = $1;

-- name: DeleteApnsTokensByDevice :exec
DELETE FROM apns_tokens WHERE device_id = $1;
