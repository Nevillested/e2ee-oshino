-- name: BlockContact :exec
INSERT INTO contact_blocks (account_id, peer_account_id)
VALUES ($1, $2)
ON CONFLICT (account_id, peer_account_id) DO NOTHING;

-- name: UnblockContact :exec
DELETE FROM contact_blocks WHERE account_id = $1 AND peer_account_id = $2;

-- name: IsBlockedEitherWay :one
SELECT EXISTS(
    SELECT 1 FROM contact_blocks
    WHERE (account_id = $1 AND peer_account_id = $2)
       OR (account_id = $2 AND peer_account_id = $1)
);

-- name: GetBlockedPeers :many
-- Кого заблокировал я сам.
SELECT peer_account_id FROM contact_blocks WHERE account_id = $1;

-- name: GetPeersWhoBlockedMe :many
-- Кто заблокировал меня.
SELECT account_id FROM contact_blocks WHERE peer_account_id = $1;
