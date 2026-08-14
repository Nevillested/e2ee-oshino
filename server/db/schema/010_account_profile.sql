ALTER TABLE accounts
    ADD COLUMN language TEXT NOT NULL DEFAULT 'en',
    ADD COLUMN email TEXT,
    ADD COLUMN avatar_object_key TEXT;
