package api

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"server/internal/db"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

type RegisterPushTokenRequest struct {
	DeviceID string `json:"device_id"`
	FcmToken string `json:"fcm_token"`
}

type UnregisterPushTokenRequest struct {
	DeviceID string `json:"device_id"`
}

// сохраняет/обновляет FCM-токен устройства — сервер использует его,
// чтобы разбудить приложение push-ом, когда устройство офлайн (не
// подключено по WebSocket) и ему пришло сообщение или звонок
func NewRegisterPushTokenHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {

		//проверяем Токен
		var _, ErrTokCheck = CheckToken(w, r, queries)
		if ErrTokCheck != nil {
			log.Printf("ошибка проверки токена: %v", ErrTokCheck)
			return
		}

		var NewRequest RegisterPushTokenRequest
		var DecodeError = json.NewDecoder(r.Body).Decode(&NewRequest)
		if DecodeError != nil {
			log.Printf("push/register: ошибка декодирования JSON: %v", DecodeError)
			http.Error(w, "Ошибка декодирования JSON", http.StatusBadRequest)
			return
		}

		if len(NewRequest.FcmToken) == 0 {
			log.Printf("push/register: пустой fcm_token, device_id=%s", NewRequest.DeviceID)
			http.Error(w, "Пустой fcm_token", http.StatusBadRequest)
			return
		}

		var DeviceID pgtype.UUID
		var ScanUuidErr = DeviceID.Scan(NewRequest.DeviceID)
		if ScanUuidErr != nil {
			log.Printf("push/register: ошибка конвертации Device ID %q: %v", NewRequest.DeviceID, ScanUuidErr)
			http.Error(w, "Ошибка конвертации Device ID", http.StatusBadRequest)
			return
		}

		var SqlErr = queries.UpsertPushToken(r.Context(), db.UpsertPushTokenParams{
			DeviceID: DeviceID,
			FcmToken: NewRequest.FcmToken,
		})
		if SqlErr != nil {
			log.Printf("push/register: ошибка сохранения push-токена (device_id=%s): %v", NewRequest.DeviceID, SqlErr)
			http.Error(w, "Ошибка сохранения push-токена", http.StatusInternalServerError)
			return
		}

		log.Printf("push/register: токен сохранён для device_id=%s", NewRequest.DeviceID)
		w.WriteHeader(http.StatusOK)
	}
}

// отвязывает FCM-токен от устройства — вызывается клиентом при выходе из
// аккаунта (см. account_actions.dart). Без этого push-токен физического
// телефона оставался висеть в базе на СТАРОМ device_id: если после выхода
// на этом же телефоне логинились в ДРУГОЙ аккаунт, сообщения старому
// аккаунту всё ещё будили этот телефон пушем (тот же FCM-токен, что и у
// новой сессии, просто под другим device_id).
func NewUnregisterPushTokenHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {

		var session, ErrTokCheck = CheckToken(w, r, queries)
		if ErrTokCheck != nil {
			log.Printf("ошибка проверки токена: %v", ErrTokCheck)
			return
		}

		var NewRequest UnregisterPushTokenRequest
		var DecodeError = json.NewDecoder(r.Body).Decode(&NewRequest)
		if DecodeError != nil {
			log.Printf("push/unregister: ошибка декодирования JSON: %v", DecodeError)
			http.Error(w, "Ошибка декодирования JSON", http.StatusBadRequest)
			return
		}

		var DeviceID pgtype.UUID
		var ScanUuidErr = DeviceID.Scan(NewRequest.DeviceID)
		if ScanUuidErr != nil {
			log.Printf("push/unregister: ошибка конвертации Device ID %q: %v", NewRequest.DeviceID, ScanUuidErr)
			http.Error(w, "Ошибка конвертации Device ID", http.StatusBadRequest)
			return
		}

		// Устройство должно принадлежать тому же аккаунту, что и текущая
		// сессия — иначе любой залогиненный пользователь мог бы отключить
		// push чужому устройству, просто подобрав/подсмотрев его device_id.
		var owner, OwnerErr = queries.GetLoginByDeviceID(r.Context(), DeviceID)
		if OwnerErr != nil {
			if errors.Is(OwnerErr, pgx.ErrNoRows) {
				// Устройства уже нет — отвязывать нечего, это не ошибка.
				w.WriteHeader(http.StatusOK)
				return
			}
			log.Printf("push/unregister: ошибка поиска владельца устройства %s: %v", NewRequest.DeviceID, OwnerErr)
			http.Error(w, "Ошибка поиска владельца устройства", http.StatusInternalServerError)
			return
		}
		if owner.AccountID != session.AccountID {
			http.Error(w, "Устройство принадлежит другому аккаунту", http.StatusForbidden)
			return
		}

		var SqlErr = queries.DeletePushTokenByDevice(r.Context(), DeviceID)
		if SqlErr != nil {
			log.Printf("push/unregister: ошибка удаления push-токена (device_id=%s): %v", NewRequest.DeviceID, SqlErr)
			http.Error(w, "Ошибка удаления push-токена", http.StatusInternalServerError)
			return
		}

		log.Printf("push/unregister: токен удалён для device_id=%s", NewRequest.DeviceID)
		w.WriteHeader(http.StatusOK)
	}
}
