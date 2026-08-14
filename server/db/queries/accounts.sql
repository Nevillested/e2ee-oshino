-- name: CreateAccount :one
INSERT INTO accounts (login, password_hash, totp_secret)
VALUES ($1, $2, $3)
RETURNING *;

-- name: GetAccountByLogin :one
SELECT * FROM accounts WHERE login = $1;

-- name: DeleteAccount :exec
DELETE FROM accounts WHERE id = $1;

-- name: GetAccountByID :one
SELECT * FROM accounts WHERE id = $1;

-- name: UpdateAccountLanguage :exec
UPDATE accounts SET language = $2 WHERE id = $1;

-- name: UpdateAccountEmail :exec
UPDATE accounts SET email = $2 WHERE id = $1;

-- name: UpdateAccountAvatar :exec
UPDATE accounts SET avatar_object_key = $2 WHERE id = $1;

-- name: GetAccountAvatarKey :one
SELECT avatar_object_key FROM accounts WHERE id = $1;

-- name: UpdateAccountPasswordHash :exec
UPDATE accounts SET password_hash = $2 WHERE id = $1;

-- name: UpdateAccountTotpSecret :exec
UPDATE accounts SET totp_secret = $2 WHERE id = $1;