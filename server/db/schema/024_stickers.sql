-- Стикерпаки. Загружает любой пользователь (ZIP: PNG/WebP — статичные, TGS —
-- анимированные Lottie), файлы — на диске Москвы (STICKERS_DIR), здесь — паки,
-- стикеры и кто какие паки добавил себе в панель. В сообщении уходит только
-- id стикера (внутри шифрования); по нему получатель узнаёт пак и скачивает
-- его целиком.
CREATE TABLE sticker_packs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- удалён автором: файлов больше нет, у всех из панели убран; строка
    -- остаётся, чтобы стикер из старой переписки знал "пак удалён автором"
    deleted_at TIMESTAMPTZ
);

CREATE TABLE stickers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pack_id UUID NOT NULL REFERENCES sticker_packs(id) ON DELETE CASCADE,
    -- порядковый номер в паке, с 0
    position INT NOT NULL,
    format TEXT NOT NULL CHECK (format IN ('png', 'webp', 'tgs')),
    file_path TEXT NOT NULL,
    size_bytes INT NOT NULL,
    UNIQUE (pack_id, position)
);

-- Паки в панели пользователя; новые — первыми (added_at DESC).
CREATE TABLE account_sticker_packs (
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    pack_id UUID NOT NULL REFERENCES sticker_packs(id) ON DELETE CASCADE,
    added_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, pack_id)
);
