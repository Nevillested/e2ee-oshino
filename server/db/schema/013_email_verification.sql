-- Почта должна однозначно указывать на один аккаунт — иначе непонятно,
-- кому из владельцев отдавать доступ по коду восстановления, если один
-- email привязан к нескольким аккаунтам. NULL (почта не указана) при этом
-- по стандарту Postgres не считается дубликатом сам с собой — UNIQUE
-- спокойно допускает сколько угодно NULL.
ALTER TABLE accounts ADD CONSTRAINT accounts_email_unique UNIQUE (email);

-- Код подтверждения новой почты (см. account_email_verification.go) — по
-- структуре один в один как password_reset_tokens, только дополнительно
-- хранит саму подтверждаемую почту: адрес ещё не записан в accounts.email,
-- пока код не введён верно.
CREATE TABLE email_verification_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    email TEXT NOT NULL,
    token_hash TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    attempts INT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_email_verification_tokens_account ON email_verification_tokens(account_id);
