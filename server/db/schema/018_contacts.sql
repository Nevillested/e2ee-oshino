-- "Контакты" — раньше на сервере не было понятия "кто с кем переписывается"
-- вообще, только блокировки (contact_blocks). Нужно для приватности профиля
-- (уровень "только контакты") и для прицельной (не широковещательной, как
-- avatar_changed) доставки profile_updated. Заполняется автоматически, обеими
-- строками сразу, в момент первого обмена сообщением между двумя аккаунтами
-- (см. websocket.go) — никакого отдельного действия "добавить в контакты"
-- пользователю выполнять не нужно.
CREATE TABLE contacts (
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    peer_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, peer_account_id)
);
