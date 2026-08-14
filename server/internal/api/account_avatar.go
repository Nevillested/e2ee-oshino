package api

import (
	"errors"
	"io"
	"log"
	"net/http"
	"os"
	"server/internal/db"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/minio/minio-go/v7"
)

// Фото профиля — сознательно НЕ шифруется (в отличие от вложений в
// переписке): его должен видеть кто угодно из контактов, а честная схема
// с расшариванием ключа каждому контакту отдельно (как profile key у
// Signal) — отдельная, гораздо более объёмная задача. Ключ объекта в
// MinIO фиксированный (avatar_<account_id>) — новая загрузка просто
// перезаписывает старый файл, не нужно отдельно чистить прежние версии.
func avatarObjectKey(accountID string) string {
	return "avatar_" + accountID
}

func NewUploadAvatarHandler(queries *db.Queries, minioClient *minio.Client) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var Session, err = CheckToken(w, r, queries)
		if err != nil {
			return
		}

		file, header, formErr := r.FormFile("file")
		if formErr != nil {
			http.Error(w, "ошибка получения файла из запроса", http.StatusBadRequest)
			return
		}
		defer file.Close()

		var accountIDStr = Session.AccountID.String()
		var objectKey = avatarObjectKey(accountIDStr)

		var _, uploadErr = minioClient.PutObject(
			r.Context(),
			os.Getenv("MINIO_BUCKET"),
			objectKey,
			file,
			header.Size,
			minio.PutObjectOptions{ContentType: "image/jpeg"},
		)
		if uploadErr != nil {
			log.Printf("ошибка загрузки аватара в MinIO: %v", uploadErr)
			http.Error(w, "ошибка загрузки файла", http.StatusInternalServerError)
			return
		}

		var SqlErr = queries.UpdateAccountAvatar(r.Context(), db.UpdateAccountAvatarParams{
			ID:              Session.AccountID,
			AvatarObjectKey: pgtype.Text{String: objectKey, Valid: true},
		})
		if SqlErr != nil {
			http.Error(w, "ошибка сохранения аватара", http.StatusInternalServerError)
			return
		}

		w.WriteHeader(http.StatusOK)
	}
}

// Отдать аватар любого аккаунта по его ID — доступ проверяем только на
// уровне "это вообще авторизованный пользователь приложения" (как и
// остальные запросы), без дополнительных ограничений: фото профиля не
// секрет, его и так видят все контакты в общем списке чатов.
func NewGetAvatarHandler(queries *db.Queries, minioClient *minio.Client) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var _, err = CheckToken(w, r, queries)
		if err != nil {
			return
		}

		var accountIDStr = r.PathValue("account_id")
		var accountID pgtype.UUID
		if ScanErr := accountID.Scan(accountIDStr); ScanErr != nil {
			http.Error(w, "Ошибка конвертации account_id", http.StatusBadRequest)
			return
		}

		var avatarKey, SqlErr = queries.GetAccountAvatarKey(r.Context(), accountID)
		if SqlErr != nil {
			if errors.Is(SqlErr, pgx.ErrNoRows) {
				http.Error(w, "Аккаунт не найден", http.StatusNotFound)
			} else {
				http.Error(w, "Ошибка поиска аккаунта", http.StatusInternalServerError)
			}
			return
		}
		if !avatarKey.Valid {
			http.Error(w, "У аккаунта нет фото профиля", http.StatusNotFound)
			return
		}

		object, ObjErr := minioClient.GetObject(r.Context(), os.Getenv("MINIO_BUCKET"), avatarKey.String, minio.GetObjectOptions{})
		if ObjErr != nil {
			http.Error(w, "Ошибка получения файла", http.StatusInternalServerError)
			return
		}
		defer object.Close()

		w.Header().Set("Content-Type", "image/jpeg")
		if _, CopyErr := io.Copy(w, object); CopyErr != nil {
			log.Printf("ошибка отдачи аватара: %v", CopyErr)
		}
	}
}
