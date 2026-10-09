-- Горячий буфер медиа на московском сервере (см. internal/api/media_staging.go).
-- storage: 'local' — файл лежит на диске Москвы и ждёт, пока его скачает
-- получатель; 'archive' — файл в MinIO на NAS (архив). Все строки, созданные
-- до этой миграции, лежат в MinIO — отсюда дефолт 'archive'.
-- delivered_at — когда получатель скачал файл целиком (или подтвердил
-- получение сам). После этого файл можно переносить в архив.
ALTER TABLE media_files
    ADD COLUMN storage TEXT NOT NULL DEFAULT 'archive'
        CHECK (storage IN ('local', 'archive')),
    ADD COLUMN delivered_at TIMESTAMPTZ;

CREATE INDEX idx_media_files_staged ON media_files (created_at) WHERE storage = 'local';
