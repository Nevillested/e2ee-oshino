CREATE TABLE pending_messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    to_device_id UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    ciphertext TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);