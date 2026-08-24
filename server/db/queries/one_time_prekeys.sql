-- name: CreateOneTimePrekeys :many
INSERT INTO one_time_prekeys (device_id, pubkey)
SELECT $1, unnest(sqlc.arg(pubkeys)::bytea[])
RETURNING id, device_id, pubkey, used, created_at;

-- name: CountUnusedOneTimePrekeys :one
SELECT count(*) FROM one_time_prekeys WHERE device_id = $1 AND used = false;