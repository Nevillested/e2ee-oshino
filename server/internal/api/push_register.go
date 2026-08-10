package api

import (
	"encoding/json"
	"log"
	"net/http"
	"server/internal/db"

	"github.com/jackc/pgx/v5/pgtype"
)

type RegisterPushTokenRequest struct {
	DeviceID string `json:"device_id"`
	FcmToken string `json:"fcm_token"`
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
			http.Error(w, "Ошибка декодирования JSON", http.StatusBadRequest)
			return
		}

		if len(NewRequest.FcmToken) == 0 {
			http.Error(w, "Пустой fcm_token", http.StatusBadRequest)
			return
		}

		var DeviceID pgtype.UUID
		var ScanUuidErr = DeviceID.Scan(NewRequest.DeviceID)
		if ScanUuidErr != nil {
			http.Error(w, "Ошибка конвертации Device ID", http.StatusBadRequest)
			return
		}

		var SqlErr = queries.UpsertPushToken(r.Context(), db.UpsertPushTokenParams{
			DeviceID: DeviceID,
			FcmToken: NewRequest.FcmToken,
		})
		if SqlErr != nil {
			http.Error(w, "Ошибка сохранения push-токена", http.StatusInternalServerError)
			return
		}

		w.WriteHeader(http.StatusOK)
	}
}
