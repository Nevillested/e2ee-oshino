-- name: CreateSession :one
INSERT INTO sessions (account_id, token_hash, expires_at)
VALUES ($1, $2, $3)
RETURNING *;

-- name: GetValidSessionByToken :one
SELECT * FROM sessions
WHERE token_hash = $1 AND expires_at > now();

-- name: ExtendSession :exec
UPDATE sessions
SET expires_at = $2
WHERE id = $1;

-- name: RevokeOtherSessions :exec
DELETE FROM sessions WHERE account_id = $1 AND id != $2;