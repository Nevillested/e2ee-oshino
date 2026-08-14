-- Какие чаты у аккаунта отключены (полный мьют, включая push) — само
-- по себе только пара (кто, кого), наличие строки и есть "замьючено".
CREATE TABLE chat_mutes (
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    peer_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, peer_account_id)
);
