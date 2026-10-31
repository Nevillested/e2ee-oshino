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
// аккаунта (OshinobuCore.logout). Без этого push-токен физического
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
		if SqlErr == nil {
			SqlErr = queries.DeleteApnsTokensByDevice(r.Context(), DeviceID)
		}
		if SqlErr != nil {
			log.Printf("push/unregister: ошибка удаления push-токена (device_id=%s): %v", NewRequest.DeviceID, SqlErr)
			http.Error(w, "Ошибка удаления push-токена", http.StatusInternalServerError)
			return
		}

		log.Printf("push/unregister: токен удалён для device_id=%s", NewRequest.DeviceID)
		w.WriteHeader(http.StatusOK)
	}
}

type RegisterApnsTokensRequest struct {
	DeviceID string `json:"device_id"`
	// Обычный токен (уведомления о сообщениях) и VoIP (PushKit, звонки);
	// пустой — "не менять": iOS выдаёт их в разное время.
	AlertToken string `json:"alert_token,omitempty"`
	VoipToken  string `json:"voip_token,omitempty"`
	// Сборка из Xcode — development APNs (sandbox), иначе production.
	Sandbox bool `json:"sandbox"`
}

// POST /push/register-apns — push-токены iOS-устройства (см. sendPush).
// Устройство должно принадлежать аккаунту сессии.
func NewRegisterApnsTokensHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		session, err := CheckToken(w, r, queries)
		if err != nil {
			log.Printf("ошибка проверки токена: %v", err)
			return
		}

		var req RegisterApnsTokensRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "Ошибка декодирования JSON", http.StatusBadRequest)
			return
		}
		if req.AlertToken == "" && req.VoipToken == "" {
			http.Error(w, "Нет ни одного токена", http.StatusBadRequest)
			return
		}
		if !isAPNsToken(req.AlertToken) || !isAPNsToken(req.VoipToken) {
			http.Error(w, "Неверный формат токена", http.StatusBadRequest)
			return
		}

		var deviceID pgtype.UUID
		if err := deviceID.Scan(req.DeviceID); err != nil {
			http.Error(w, "Ошибка конвертации Device ID", http.StatusBadRequest)
			return
		}
		owner, err := queries.GetLoginByDeviceID(r.Context(), deviceID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				http.Error(w, "Устройство не найдено", http.StatusNotFound)
				return
			}
			log.Printf("push/register-apns: ошибка поиска владельца устройства %s: %v", req.DeviceID, err)
			http.Error(w, "Ошибка поиска владельца устройства", http.StatusInternalServerError)
			return
		}
		if owner.AccountID != session.AccountID {
			http.Error(w, "Устройство принадлежит другому аккаунту", http.StatusForbidden)
			return
		}

		alert := pgtype.Text{String: req.AlertToken, Valid: req.AlertToken != ""}
		voip := pgtype.Text{String: req.VoipToken, Valid: req.VoipToken != ""}
		if err := queries.DeleteApnsTokenDuplicates(r.Context(), db.DeleteApnsTokenDuplicatesParams{
			DeviceID: deviceID, AlertToken: alert, VoipToken: voip,
		}); err != nil {
			log.Printf("push/register-apns: ошибка снятия старых копий токена: %v", err)
		}
		if err := queries.UpsertApnsTokens(r.Context(), db.UpsertApnsTokensParams{
			DeviceID: deviceID, AlertToken: alert, VoipToken: voip, Sandbox: req.Sandbox,
		}); err != nil {
			log.Printf("push/register-apns: ошибка сохранения (device_id=%s): %v", req.DeviceID, err)
			http.Error(w, "Ошибка сохранения push-токена", http.StatusInternalServerError)
			return
		}

		log.Printf("push/register-apns: токены сохранены для device_id=%s (alert=%t voip=%t sandbox=%t)",
			req.DeviceID, alert.Valid, voip.Valid, req.Sandbox)
		w.WriteHeader(http.StatusOK)
	}
}

// isAPNsToken — пусто или hex (токен идёт в путь запроса к Apple).
func isAPNsToken(t string) bool {
	if len(t) > 200 {
		return false
	}
	for _, c := range t {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
			return false
		}
	}
	return true
}
