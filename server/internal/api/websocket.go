package api

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"log"
	"net/http"
	"server/internal/db"
	"server/internal/push"
	"strings"
	"time"

	"github.com/coder/websocket"
	"github.com/jackc/pgx/v5/pgtype"
)

type WSMsgFrom struct {
	ToDeviceId string `json:"ToDeviceId"`
	Ciphertext string `json:"Ciphertext"`
	Type       string `json:"Type"`
	DeliveryId string `json:"DeliveryId"`
}

type WSMsgRelay struct {
	ToDeviceId string `json:"ToDeviceId"`
	Ciphertext string `json:"Ciphertext"`
	Type       string `json:"Type"`
	DeliveryId string `json:"DeliveryId"`
}

type WSMsgTo struct {
	Type string `json:"Type"`
}

func generateDeliveryID() string {
	buf := make([]byte, 16)
	rand.Read(buf)
	return hex.EncodeToString(buf)
}

func queuePendingMessage(ctx context.Context, queries *db.Queries, toDeviceId string, message []byte) {
	var toDeviceUUID pgtype.UUID
	if err := toDeviceUUID.Scan(toDeviceId); err != nil {
		log.Printf("Ошибка конвертации Device ID при постановке в очередь: %v", err)
		return
	}

	var params db.SavePendingMessageParams
	params.ToDeviceID = toDeviceUUID
	params.Ciphertext = string(message)

	if err := queries.SavePendingMessage(ctx, params); err != nil {
		log.Printf("Ошибка добавления сообщения в очередь: %v", err)
		return
	}

	// Будим получателя push-ом — сам он не содержит текста сообщения,
	// только сигнал "подключись к серверу", сообщение уже лежит в
	// pending_messages и придёт по обычному зашифрованному каналу.
	if token, err := queries.GetPushTokenByDevice(ctx, toDeviceUUID); err == nil {
		push.SendDataPush(ctx, token.FcmToken, push.TypeMessage)
	}
}

func NewWebSocketHandler(queries *db.Queries, registry *ConnectionRegistry, acks *AckRegistry) func(http.ResponseWriter, *http.Request) {

	return func(w http.ResponseWriter, r *http.Request) {

		var _, ErrTokCheck = CheckToken(w, r, queries)
		if ErrTokCheck != nil {
			log.Printf("ошибка проверки токена: %v", ErrTokCheck)
			return
		}

		var ws_object, ws_error = websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if ws_error != nil {
			log.Printf("ошибка создания вебсокета: %v", ws_error)
			return
		}
		defer ws_object.CloseNow()

		var DeviceID string = r.URL.Query().Get("device_id")

		registry.Add(DeviceID, ws_object)
		defer registry.RemoveIfCurrent(DeviceID, ws_object)

		var ToDeviceIDUUID pgtype.UUID
		ScanUuidErr := ToDeviceIDUUID.Scan(DeviceID)
		if ScanUuidErr != nil {
			log.Printf("ошибка конвертации Device ID: %v", ScanUuidErr)
			return
		}

		var PendingMessages []db.PendingMessage
		PendingMessages, SqlErr := queries.GetPendingMessages(r.Context(), ToDeviceIDUUID)
		if SqlErr != nil {
			log.Printf("ошибка получения сообщений из бд: %v", SqlErr)
		} else {
			for _, msg := range PendingMessages {
				var err = ws_object.Write(r.Context(), websocket.MessageText, []byte(msg.Ciphertext))
				if err != nil {
					log.Printf("ошибка отправки сообщения: %v", err)
				}
			}
		}

		SqlErr = queries.DeletePendingMessages(r.Context(), ToDeviceIDUUID)
		if SqlErr != nil {
			log.Printf("ошибка удаления сообщений в бд: %v", SqlErr)
			return
		}

	readLoop:
		for {
			var message_type, message, read_error = ws_object.Read(r.Context())
			if read_error != nil {
				log.Printf("ошибка чтения сообщения из вебсокета: %v", read_error)
				break
			}

			var NewWSMsgFrom WSMsgFrom
			var DecodeError = json.Unmarshal(message, &NewWSMsgFrom)
			if DecodeError != nil {
				log.Printf("ошибка декодирования сообщения: %v", DecodeError)
				continue
			}

			var MessageType string = NewWSMsgFrom.Type

			if MessageType == "ack" {
				acks.Fulfill(NewWSMsgFrom.DeliveryId)
				continue
			}

			var ConnReceiver, Status = registry.Get(NewWSMsgFrom.ToDeviceId)

			if MessageType == "message" {

				if Status == true {

					deliveryID := generateDeliveryID()
					relay := WSMsgRelay{
						ToDeviceId: NewWSMsgFrom.ToDeviceId,
						Ciphertext: NewWSMsgFrom.Ciphertext,
						Type:       NewWSMsgFrom.Type,
						DeliveryId: deliveryID,
					}
					relayBytes, _ := json.Marshal(relay)

					ackChan := acks.Wait(deliveryID)
					var write_error = ConnReceiver.Write(r.Context(), message_type, relayBytes)

					if write_error != nil {
						log.Printf("получатель считался онлайн, но запись не удалась (зомби-соединение): %v", write_error)
						acks.Cancel(deliveryID)
						registry.RemoveIfCurrent(NewWSMsgFrom.ToDeviceId, ConnReceiver)
						queuePendingMessage(r.Context(), queries, NewWSMsgFrom.ToDeviceId, message)
						continue
					}

					select {
					case <-ackChan:

					case <-time.After(5 * time.Second):
						log.Printf("получатель не подтвердил доставку за 5с, ставим в очередь")
						acks.Cancel(deliveryID)
						registry.RemoveIfCurrent(NewWSMsgFrom.ToDeviceId, ConnReceiver)
						queuePendingMessage(r.Context(), queries, NewWSMsgFrom.ToDeviceId, message)
					}

				} else {
					log.Printf("Сообщение поставлено в очередь до тех пор, пока устройство не будет в сети")
					queuePendingMessage(r.Context(), queries, NewWSMsgFrom.ToDeviceId, message)
				}

			} else if strings.HasPrefix(MessageType, "call_") {

				if Status == true {
					var write_error = ConnReceiver.Write(r.Context(), message_type, message)
					if write_error != nil {
						log.Printf("ошибка отправки сообщения в вебсокет: %v", write_error)
						break readLoop
					}
				} else {
					var NewWSMsgTo WSMsgTo
					NewWSMsgTo.Type = "call_unavailable"
					respBytes, marshalErr := json.Marshal(NewWSMsgTo)
					if marshalErr != nil {
						log.Printf("ошибка кодирования ответа: %v", marshalErr)
						continue
					}
					var write_error = ws_object.Write(r.Context(), websocket.MessageText, respBytes)
					if write_error != nil {
						log.Printf("ошибка отправки ответа отправителю: %v", write_error)
						break readLoop
					}
				}

			} else {
				log.Printf("неизвестный тип сообщения: %s", MessageType)
			}

		}

	}

}
