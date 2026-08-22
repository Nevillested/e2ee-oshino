-- name: UpsertContactsPair :exec
INSERT INTO contacts (account_id, peer_account_id)
VALUES ($1, $2), ($2, $1)
ON CONFLICT DO NOTHING;

-- name: IsContact :one
SELECT EXISTS(
    SELECT 1 FROM contacts WHERE account_id = $1 AND peer_account_id = $2
);

-- name: GetContactAccountIDs :many
SELECT peer_account_id FROM contacts WHERE account_id = $1;
