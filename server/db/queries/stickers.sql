-- name: CreateStickerPack :exec
INSERT INTO sticker_packs (id, owner_account_id, title) VALUES ($1, $2, $3);

-- name: CreateSticker :exec
INSERT INTO stickers (id, pack_id, position, format, file_path, size_bytes)
VALUES ($1, $2, $3, $4, $5, $6);

-- name: CountOwnStickerPacks :one
SELECT count(*) FROM sticker_packs WHERE owner_account_id = $1 AND deleted_at IS NULL;

-- name: GetStickerPack :one
SELECT * FROM sticker_packs WHERE id = $1;

-- name: ListPackStickers :many
SELECT id, position, format, file_path, size_bytes FROM stickers WHERE pack_id = $1 ORDER BY position;

-- name: GetSticker :one
SELECT s.id, s.pack_id, s.format, s.file_path, p.deleted_at
FROM stickers s JOIN sticker_packs p ON p.id = s.pack_id
WHERE s.id = $1;

-- name: InstallStickerPack :exec
-- Повторное добавление — переносит пак в начало панели.
INSERT INTO account_sticker_packs (account_id, pack_id) VALUES ($1, $2)
ON CONFLICT (account_id, pack_id) DO UPDATE SET added_at = now();

-- name: UninstallStickerPack :exec
DELETE FROM account_sticker_packs WHERE account_id = $1 AND pack_id = $2;

-- name: IsStickerPackInstalled :one
SELECT EXISTS(SELECT 1 FROM account_sticker_packs WHERE account_id = $1 AND pack_id = $2);

-- name: ListInstalledStickerPacks :many
SELECT p.* FROM account_sticker_packs a JOIN sticker_packs p ON p.id = a.pack_id
WHERE a.account_id = $1 AND p.deleted_at IS NULL
ORDER BY a.added_at DESC;

-- name: MarkStickerPackDeleted :exec
UPDATE sticker_packs SET deleted_at = now() WHERE id = $1 AND deleted_at IS NULL;

-- name: UninstallStickerPackForEveryone :exec
DELETE FROM account_sticker_packs WHERE pack_id = $1;
