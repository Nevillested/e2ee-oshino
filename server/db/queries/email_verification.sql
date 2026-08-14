-- name: CreateEmailVerificationToken :one
INSERT INTO email_verification_tokens (account_id, email, token_hash, expires_at)
VALUES ($1, $2, $3, $4)
RETURNING *;

-- name: GetLatestEmailVerificationToken :one
SELECT * FROM email_verification_tokens
WHERE account_id = $1
ORDER BY created_at DESC
LIMIT 1;

-- name: IncrementEmailVerificationAttempts :exec
UPDATE email_verification_tokens SET attempts = attempts + 1 WHERE id = $1;

-- name: DeleteEmailVerificationTokensForAccount :exec
DELETE FROM email_verification_tokens WHERE account_id = $1;
