-- Обои чатов: картинка, которую аккаунт поставил фоном чата с собеседником
-- (или которую ему поставил собеседник — "установить также у собеседника").
-- Как и фото профиля, хранится открыто, прямо в базе на Москве: после
-- переустановки приложения обои подтягиваются отсюда.
CREATE TABLE chat_wallpapers (
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    peer_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    image BYTEA NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, peer_account_id)
);
