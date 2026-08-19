ALTER TABLE message_reports ADD COLUMN reviewed_at TIMESTAMPTZ;
ALTER TABLE feedback ADD COLUMN reviewed_at TIMESTAMPTZ;
