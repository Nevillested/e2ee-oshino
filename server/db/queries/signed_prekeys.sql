-- name: UpsertSignedPrekey :one
INSERT INTO signed_prekeys (device_id, pubkey, signature)
VALUES ($1, $2, $3)
ON CONFLICT (device_id) DO UPDATE
SET pubkey = EXCLUDED.pubkey, signature = EXCLUDED.signature, created_at = now()
RETURNING *;