-- name: SetChatWallpaper :one
INSERT INTO chat_wallpapers (account_id, peer_account_id, image)
VALUES ($1, $2, $3)
ON CONFLICT (account_id, peer_account_id) DO UPDATE SET image = EXCLUDED.image, updated_at = now()
RETURNING updated_at;

-- name: DeleteChatWallpaper :exec
DELETE FROM chat_wallpapers WHERE account_id = $1 AND peer_account_id = $2;

-- name: GetChatWallpaper :one
SELECT image FROM chat_wallpapers WHERE account_id = $1 AND peer_account_id = $2;

-- name: ListChatWallpapers :many
SELECT peer_account_id, updated_at FROM chat_wallpapers WHERE account_id = $1;
