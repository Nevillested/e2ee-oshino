-- Статус, дата рождения и приватность профиля. Логин редактированию не
-- подлежит (это база, в схеме и не появляется).
--
-- Видимость (0/1/2): 0 = никто, 1 = все, 2 = только контакты (см. 018_contacts.sql).
-- find_by_login_visibility осмысленно только как 0/1 — "только контакты"
-- для самой возможности найтись по логину не имеет смысла (это и есть
-- единственный способ впервые стать чьим-то контактом).
-- Дефолт везде 1 ("все") — сознательное решение, максимально открыто по
-- умолчанию, пользователь сам закрывает то, что хочет.
ALTER TABLE accounts
    ADD COLUMN status_text TEXT,
    ADD COLUMN birthday DATE,
    ADD COLUMN find_by_login_visibility SMALLINT NOT NULL DEFAULT 1
        CHECK (find_by_login_visibility IN (0, 1)),
    ADD COLUMN avatar_visibility SMALLINT NOT NULL DEFAULT 1
        CHECK (avatar_visibility IN (0, 1, 2)),
    ADD COLUMN birthday_visibility SMALLINT NOT NULL DEFAULT 1
        CHECK (birthday_visibility IN (0, 1, 2)),
    ADD COLUMN status_visibility SMALLINT NOT NULL DEFAULT 1
        CHECK (status_visibility IN (0, 1, 2));
