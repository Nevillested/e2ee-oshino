-- name: CreateAccount :one
INSERT INTO accounts (login, password_hash, totp_secret)
VALUES ($1, $2, $3)
RETURNING *;

-- name: GetAccountByLogin :one
SELECT * FROM accounts WHERE login = $1;