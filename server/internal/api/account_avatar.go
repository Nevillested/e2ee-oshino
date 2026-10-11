package api

import (
	"context"
	"errors"
	"io"
	"log"
	"net/http"
	"server/internal/db"
	"strconv"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

// Фото профиля — сознательно НЕ шифруется (в отличие от вложений в
// переписке): его должен видеть кто угодно из контактов, а честная схема
// с расшариванием ключа каждому контакту отдельно (как profile key у
// Signal) — отдельная, гораздо более объёмная задача.
//
// Хранится в базе на Москве, в самой таблице аккаунтов (accounts.avatar_image),
// как и весь остальной профиль, и только оттуда отдаётся — от NAS фото
// профиля не зависит (см. 023_account_avatar_image.sql).

// maxAvatarBytes — клиент присылает уже сжатый JPEG (десятки КБ); запас —
// на большой исходник, но не мегабайты в каждой строке аккаунта.
const maxAvatarBytes = 2 * 1024 * 1024

func NewUploadAvatarHandler(queries *db.Queries, registry *ConnectionRegistry) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var Session, err = CheckToken(w, r, queries)
		if err != nil {
			return
		}

		r.Body = http.MaxBytesReader(w, r.Body, maxAvatarBytes+64*1024)
		file, _, formErr := r.FormFile("file")
		if formErr != nil {
			http.Error(w, "ошибка получения файла из запроса", http.StatusBadRequest)
			return
		}
		defer file.Close()

		image, readErr := io.ReadAll(io.LimitReader(file, maxAvatarBytes+1))
		if readErr != nil || len(image) == 0 {
			http.Error(w, "ошибка чтения файла", http.StatusBadRequest)
			return
		}
		if len(image) > maxAvatarBytes {
			http.Error(w, "фото слишком большое", http.StatusRequestEntityTooLarge)
			return
		}

		if SqlErr := queries.UpdateAccountAvatarImage(r.Context(), db.UpdateAccountAvatarImageParams{
			ID:          Session.AccountID,
			AvatarImage: image,
		}); SqlErr != nil {
			log.Printf("ошибка сохранения аватара: %v", SqlErr)
			http.Error(w, "ошибка сохранения аватара", http.StatusInternalServerError)
			return
		}

		// Единый механизм с status/birthday/display_name (см. ТЗ
		// пользователя — один способ обновления для всех полей профиля,
		// с учётом приватности): прицельно контактам, с учётом
		// avatar_visibility, и с доставкой офлайн-получателю при
		// следующем подключении.
		notifyProfileUpdatedIfVisible(r.Context(), queries, registry, Session.AccountID, "avatar")

		w.WriteHeader(http.StatusOK)
	}
}

// Удаление своего фото профиля.
func NewDeleteAvatarHandler(queries *db.Queries, registry *ConnectionRegistry) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var Session, err = CheckToken(w, r, queries)
		if err != nil {
			return
		}

		if SqlErr := queries.UpdateAccountAvatarImage(r.Context(), db.UpdateAccountAvatarImageParams{ID: Session.AccountID}); SqlErr != nil {
			http.Error(w, "ошибка удаления аватара", http.StatusInternalServerError)
			return
		}

		notifyProfileUpdatedIfVisible(r.Context(), queries, registry, Session.AccountID, "avatar")

		w.WriteHeader(http.StatusOK)
	}
}

// serveAvatar — общая часть для "отдать аватар по id" и "отдать СВОЙ
// аватар": байты из базы; нет фото (или аккаунта) — 404.
func serveAvatar(ctx context.Context, w http.ResponseWriter, queries *db.Queries, accountID pgtype.UUID) {
	image, SqlErr := queries.GetAccountAvatarImage(ctx, accountID)
	if SqlErr != nil {
		if errors.Is(SqlErr, pgx.ErrNoRows) {
			http.Error(w, "Аккаунт не найден", http.StatusNotFound)
		} else {
			http.Error(w, "Ошибка чтения фото профиля", http.StatusInternalServerError)
		}
		return
	}
	if len(image) == 0 {
		http.Error(w, "У аккаунта нет фото профиля", http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Content-Length", strconv.Itoa(len(image)))
	if _, WriteErr := w.Write(image); WriteErr != nil {
		log.Printf("ошибка отдачи аватара: %v", WriteErr)
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
	if blockedBetween(ctx, queries, ownerID, viewerID) {
		return false
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
func NewGetAvatarHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
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

		serveAvatar(r.Context(), w, queries, accountID)
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
func NewGetMyAvatarHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var Session, err = CheckToken(w, r, queries)
		if err != nil {
			return
		}

		serveAvatar(r.Context(), w, queries, Session.AccountID)
	}
}
