-- name: CreateFeedback :exec
INSERT INTO feedback (account_id, account_login, message, kind)
VALUES ($1, $2, $3, $4);

-- name: ListFeedback :many
SELECT * FROM feedback ORDER BY created_at DESC;

-- name: MarkFeedbackReviewed :exec
UPDATE feedback SET reviewed_at = now() WHERE id = $1;
