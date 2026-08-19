CREATE TABLE message_reports (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    reporter_account_id UUID REFERENCES accounts(id) ON DELETE SET NULL,
    reporter_login TEXT NOT NULL,
    reported_account_id UUID REFERENCES accounts(id) ON DELETE SET NULL,
    reported_login TEXT NOT NULL,
    message_text TEXT NOT NULL,
    reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE feedback (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID REFERENCES accounts(id) ON DELETE SET NULL,
    account_login TEXT NOT NULL,
    message TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
