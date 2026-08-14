-- name: MuteChat :exec
INSERT INTO chat_mutes (account_id, peer_account_id)
VALUES ($1, $2)
ON CONFLICT (account_id, peer_account_id) DO NOTHING;

-- name: UnmuteChat :exec
DELETE FROM chat_mutes WHERE account_id = $1 AND peer_account_id = $2;

-- name: IsChatMuted :one
SELECT EXISTS(SELECT 1 FROM chat_mutes WHERE account_id = $1 AND peer_account_id = $2);

-- name: GetMutedPeers :many
SELECT peer_account_id FROM chat_mutes WHERE account_id = $1;
