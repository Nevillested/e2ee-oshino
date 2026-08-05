-- name: GetIdentityAndSignedPrekey :one
SELECT d.account_id, d.identity_pubkey, d.identity_dh_pubkey, d.identity_dh_signature,
       sp.pubkey AS signed_prekey, sp.signature
FROM devices d
JOIN signed_prekeys sp ON sp.device_id = d.id
WHERE d.id = $1;

-- name: ClaimOneTimePrekey :one
UPDATE one_time_prekeys
SET used = true
WHERE id = (
    SELECT otp.id FROM one_time_prekeys otp
    WHERE otp.device_id = $1 AND otp.used = false
    ORDER BY otp.created_at
    LIMIT 1
    FOR UPDATE SKIP LOCKED
)
RETURNING *;