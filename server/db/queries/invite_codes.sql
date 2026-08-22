-- name: CreateInviteCode :one
INSERT INTO invite_codes (code) VALUES ($1) RETURNING *;

-- name: ConsumeInviteCode :one
UPDATE invite_codes
SET used_by_account_id = $2, used_at = now()
WHERE code = $1 AND used_at IS NULL
RETURNING *;

-- name: ListInviteCodes :many
SELECT ic.code, ic.created_at, ic.used_at, a.login AS used_by_login
FROM invite_codes ic
LEFT JOIN accounts a ON a.id = ic.used_by_account_id
ORDER BY ic.created_at DESC;

-- name: DeleteInviteCode :one
DELETE FROM invite_codes WHERE code = $1 RETURNING *;

-- name: GetInviteCodeByCode :one
SELECT * FROM invite_codes WHERE code = $1;
