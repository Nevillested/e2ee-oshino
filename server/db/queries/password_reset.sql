-- name: CreatePasswordResetToken :one
INSERT INTO password_reset_tokens (account_id, token_hash, expires_at)
VALUES ($1, $2, $3)
RETURNING *;

-- name: GetLatestPasswordResetToken :one
SELECT * FROM password_reset_tokens
WHERE account_id = $1
ORDER BY created_at DESC
LIMIT 1;

-- name: IncrementPasswordResetAttempts :exec
UPDATE password_reset_tokens SET attempts = attempts + 1 WHERE id = $1;

-- name: DeletePasswordResetTokensForAccount :exec
DELETE FROM password_reset_tokens WHERE account_id = $1;
