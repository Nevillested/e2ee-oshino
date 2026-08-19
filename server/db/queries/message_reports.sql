-- name: CreateReport :exec
INSERT INTO message_reports (
    reporter_account_id, reporter_login,
    reported_account_id, reported_login,
    message_text, reason
) VALUES ($1, $2, $3, $4, $5, $6);

-- name: ListReports :many
SELECT * FROM message_reports ORDER BY created_at DESC;
