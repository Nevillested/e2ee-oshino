package api

import (
	"context"
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

func NewUploadAvatarHandler(queries *db.Queries, minioClient *minio.Client, registry *ConnectionRegistry) func(http.ResponseWriter, *http.Request) {
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

		// Единый механизм с status/birthday/display_name (см. ТЗ
		// пользователя — один способ обновления для всех полей профиля,
		// с учётом приватности): прицельно контактам, с учётом
		// avatar_visibility, и с доставкой офлайн-получателю при
		// следующем подключении — не широковещательно всем подряд, как
		// раньше.
		notifyProfileUpdatedIfVisible(r.Context(), queries, registry, Session.AccountID, "avatar")

		w.WriteHeader(http.StatusOK)
	}
}

// Удаление своего фото профиля — чистим и MinIO (иначе объект просто
// вечно занимал бы место, никем не доставаемый), и саму ссылку на него
// в БД (это и есть источник истины для GetAvatarHandler — без него он
// сразу отвечает 404, даже не пытаясь смотреть в MinIO). Отсутствие
// файла в MinIO на момент удаления — не ошибка (RemoveObject тут не
// строгий, просто логируем и продолжаем очищать БД).
func NewDeleteAvatarHandler(queries *db.Queries, minioClient *minio.Client, registry *ConnectionRegistry) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var Session, err = CheckToken(w, r, queries)
		if err != nil {
			return
		}

		avatarKey, SqlErr := queries.GetAccountAvatarKey(r.Context(), Session.AccountID)
		if SqlErr == nil && avatarKey.Valid {
			if rmErr := minioClient.RemoveObject(r.Context(), os.Getenv("MINIO_BUCKET"), avatarKey.String, minio.RemoveObjectOptions{}); rmErr != nil {
				log.Printf("ошибка удаления файла аватара из MinIO: %v", rmErr)
			}
		}

		if UpdErr := queries.UpdateAccountAvatar(r.Context(), db.UpdateAccountAvatarParams{
			ID:              Session.AccountID,
			AvatarObjectKey: pgtype.Text{Valid: false},
		}); UpdErr != nil {
			http.Error(w, "ошибка удаления аватара", http.StatusInternalServerError)
			return
		}

		// Единый механизм с status/birthday/display_name (см. ТЗ
		// пользователя — один способ обновления для всех полей профиля,
		// с учётом приватности): прицельно контактам, с учётом
		// avatar_visibility, и с доставкой офлайн-получателю при
		// следующем подключении — не широковещательно всем подряд, как
		// раньше.
		notifyProfileUpdatedIfVisible(r.Context(), queries, registry, Session.AccountID, "avatar")

		w.WriteHeader(http.StatusOK)
	}
}

// serveAvatar — общая часть для "отдать аватар по id" и "отдать СВОЙ
// аватар": ищет ключ объекта в БД и стримит сам файл из MinIO.
func serveAvatar(ctx context.Context, w http.ResponseWriter, queries *db.Queries, minioClient *minio.Client, accountID pgtype.UUID) {
	var avatarKey, SqlErr = queries.GetAccountAvatarKey(ctx, accountID)
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

	object, ObjErr := minioClient.GetObject(ctx, os.Getenv("MINIO_BUCKET"), avatarKey.String, minio.GetObjectOptions{})
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

// avatarVisibleTo — те же правила видимости, что fieldVisible в
// account_profile.go (GetAccountProfileHandler), но продублированы тут:
// этот хендлер отдаёт сырые байты фото напрямую по account_id, а не через
// /account/profile/{login}, и раньше вообще не проверял AvatarVisibility —
// из-за этого смена приватности на "никто"/"только контакты" не мешала
// скачать фото по прямому запросу, а инвалидация клиентского кэша (см.
// AvatarCache.invalidate) ничего не решала: следующий же рефетч всё равно
// получал то же самое фото обратно.
func avatarVisibleTo(ctx context.Context, queries *db.Queries, ownerID, viewerID pgtype.UUID) bool {
	if ownerID == viewerID {
		return true
	}
	owner, err := queries.GetAccountByID(ctx, ownerID)
	if err != nil {
		return false
	}
	switch owner.AvatarVisibility {
	case 1:
		return true
	case 2:
		isContact, contactErr := queries.IsContact(ctx, db.IsContactParams{
			AccountID:     ownerID,
			PeerAccountID: viewerID,
		})
		return contactErr == nil && isContact
	default:
		return false
	}
}

// Отдать аватар любого аккаунта по его ID — сперва проверяем настройки
// приватности владельца (см. avatarVisibleTo), затем доступ на уровне
// "это вообще авторизованный пользователь приложения".
func NewGetAvatarHandler(queries *db.Queries, minioClient *minio.Client) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var Session, err = CheckToken(w, r, queries)
		if err != nil {
			return
		}

		var accountIDStr = r.PathValue("account_id")
		var accountID pgtype.UUID
		if ScanErr := accountID.Scan(accountIDStr); ScanErr != nil {
			http.Error(w, "Ошибка конвертации account_id", http.StatusBadRequest)
			return
		}

		if !avatarVisibleTo(r.Context(), queries, accountID, Session.AccountID) {
			http.Error(w, "У аккаунта нет фото профиля", http.StatusNotFound)
			return
		}

		serveAvatar(r.Context(), w, queries, minioClient, accountID)
	}
}

// Отдать СВОЙ аватар — account_id берётся из сессии (токена), а не из
// того, что прислал клиент. Существует ИМЕННО из-за того, что локальный
// кэш account_id на клиенте (см. Session.getAccountId на клиенте) может
// устареть (например, после пересоздания аккаунтов при чистке базы) и
// разойтись с тем, что реально означает текущий токен — раньше клиент для
// "своего" аватара пользовался тем же GET /account/avatar/{account_id},
// что и для чужих, подставляя туда СВОЙ закэшированный (и потенциально
// битый) id; этот эндпоинт делает то же самое, что уже работает для
// загрузки/удаления — доверяет только токену.
func NewGetMyAvatarHandler(queries *db.Queries, minioClient *minio.Client) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var Session, err = CheckToken(w, r, queries)
		if err != nil {
			return
		}

		serveAvatar(r.Context(), w, queries, minioClient, Session.AccountID)
	}
}
