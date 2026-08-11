package api

import (
	"encoding/json"
	"log"
	"net/http"
	"server/internal/db"

	"github.com/coder/websocket"
)

type DeclineCallRequest struct {
	DeviceID string `json:"device_id"`
	CallID   string `json:"call_id"`
}

// NewDeclineCallHandler — POST /calls/decline. Позволяет отклонить звонок,
// который ещё ждёт подключения получателя (см. PendingCallRegistry), не
// поднимая WebSocket и вообще не открывая приложение — именно так работает
// кнопка "Отклонить" в push-уведомлении о звонке (CallRingService на
// Android). В отличие от локальной остановки рингтона на этом устройстве,
// здесь мы ещё и мгновенно сообщаем звонящему, что вызов отклонён, а не
// оставляем его ждать TTL.
func NewDeclineCallHandler(queries *db.Queries, registry *ConnectionRegistry, pendingCalls *PendingCallRegistry) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		if _, err := CheckToken(w, r, queries); err != nil {
			log.Printf("calls/decline: ошибка проверки токена: %v", err)
			return
		}

		var req DeclineCallRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			log.Printf("calls/decline: ошибка декодирования JSON: %v", err)
			http.Error(w, "Ошибка декодирования JSON", http.StatusBadRequest)
			return
		}

		log.Printf("calls/decline: запрос device_id=%s call_id=%s", req.DeviceID, req.CallID)

		callerDeviceID, ok := pendingCalls.Decline(req.DeviceID, req.CallID)
		if !ok {
			// Звонок уже не ждёт (например, звонящий сам отменил, случился
			// таймаут, или это устаревшее нажатие) — отклонять нечего,
			// это не ошибка.
			log.Printf("calls/decline: для device_id=%s call_id=%s нет отложенного звонка (уже снят/устарел)", req.DeviceID, req.CallID)
			w.WriteHeader(http.StatusOK)
			return
		}

		log.Printf("calls/decline: звонок %s снят с ожидания, звонящий=%s", req.CallID, callerDeviceID)

		if callerConn, connected := registry.Get(callerDeviceID); connected {
			reject := WSMsgRelay{
				ToDeviceId: callerDeviceID,
				Ciphertext: "{}",
				Type:       "call_reject",
			}
			payload, marshalErr := json.Marshal(reject)
			if marshalErr != nil {
				log.Printf("calls/decline: ошибка кодирования сигнала звонящему: %v", marshalErr)
			} else if writeErr := callerConn.Write(r.Context(), websocket.MessageText, payload); writeErr != nil {
				log.Printf("calls/decline: не удалось уведомить звонящего: %v", writeErr)
			} else {
				log.Printf("calls/decline: звонящему %s отправлен call_reject", callerDeviceID)
			}
		} else {
			log.Printf("calls/decline: звонящий %s не в сети, уведомить не удалось", callerDeviceID)
		}

		log.Printf("calls/decline: звонок %s отклонён устройством %s", req.CallID, req.DeviceID)
		w.WriteHeader(http.StatusOK)
	}
}
