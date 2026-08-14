-- Кто кого заблокировал — та же форма, что и chat_mutes (см.
-- 011_chat_mutes.sql), но с другим смыслом: наличие строки (account_id
-- заблокировал peer_account_id) запрещает отправку сообщений И звонков в
-- ОБЕ стороны между этой парой (см. websocket.go), а не только глушит
-- push, как мьют.
CREATE TABLE contact_blocks (
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    peer_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, peer_account_id)
);
