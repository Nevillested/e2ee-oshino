CREATE TABLE media_files (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    uploaded_by_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
	recipient_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    object_key TEXT NOT NULL,
    size_bytes BIGINT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);