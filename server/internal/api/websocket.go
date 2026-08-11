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

// CallSignalPayload — минимальный разбор содержимого поля Ciphertext у
// call_*-кадров (для звонков оно не зашифровано, см. sendCallSignal на
// клиенте) — нужен только чтобы вытащить call_id и звонящего для очереди
// отложенных звонков, само содержимое (SDP и т.д.) сервер не трогает и
// пересылает как есть.
type CallSignalPayload struct {
	SenderDeviceID string `json:"sender_device_id"`
	CallID         string `json:"call_id"`
}

// Сколько ждать, прежде чем считать недозвонившийся вызов неотвеченным —
// как обычный телефонный дозвон: пуш должен успеть разбудить получателя,
// а сам получатель — успеть увидеть входящий вызов и среагировать.
const callRingTTL = 45 * time.Second

func generateDeliveryID() string {
	buf := make([]byte, 16)
	rand.Read(buf)
	return hex.EncodeToString(buf)
}

func respondCallUnavailable(ctx context.Context, ws_object *websocket.Conn) error {
	var NewWSMsgTo WSMsgTo
	NewWSMsgTo.Type = "call_unavailable"
	respBytes, marshalErr := json.Marshal(NewWSMsgTo)
	if marshalErr != nil {
		log.Printf("ошибка кодирования ответа: %v", marshalErr)
		return marshalErr
	}
	return ws_object.Write(ctx, websocket.MessageText, respBytes)
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

func NewWebSocketHandler(queries *db.Queries, registry *ConnectionRegistry, acks *AckRegistry, pendingCalls *PendingCallRegistry) func(http.ResponseWriter, *http.Request) {

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

		// Отложенные звонки доставляем первым делом, до обычных сообщений —
		// это дозвон в реальном времени, задержка тут особенно чувствуется.
		for _, frame := range pendingCalls.Take(DeviceID) {
			if err := ws_object.Write(r.Context(), websocket.MessageText, frame); err != nil {
				log.Printf("ошибка доставки отложенного звонка: %v", err)
				break
			}
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
					var callPayload CallSignalPayload
					_ = json.Unmarshal([]byte(NewWSMsgFrom.Ciphertext), &callPayload)

					var handled bool

					switch MessageType {
					case "call_offer":
						if callPayload.CallID != "" {
							toDeviceID := NewWSMsgFrom.ToDeviceId
							callID := callPayload.CallID
							pendingCalls.Start(toDeviceID, callID, DeviceID, message, callRingTTL, func() {
								if callerConn, ok := registry.Get(DeviceID); ok {
									if err := respondCallUnavailable(context.Background(), callerConn); err != nil {
										log.Printf("ошибка отправки call_unavailable по истечении ожидания: %v", err)
									}
								}
								pendingCalls.Expire(toDeviceID, callID)
							})

							var toDeviceUUID pgtype.UUID
							if uuidErr := toDeviceUUID.Scan(toDeviceID); uuidErr == nil {
								if token, err := queries.GetPushTokenByDevice(r.Context(), toDeviceUUID); err == nil {
									push.SendDataPush(r.Context(), token.FcmToken, push.TypeCall)
								}
							}
							handled = true
						}

					case "call_cancel", "call_end", "call_reject", "call_busy":
						if pendingCalls.Cancel(NewWSMsgFrom.ToDeviceId, callPayload.CallID, DeviceID) {
							handled = true
						}

					default: // call_ice, call_video_state и т.п. — буферизуем к уже ждущему звонку
						if pendingCalls.Append(NewWSMsgFrom.ToDeviceId, callPayload.CallID, message) {
							handled = true
						}
					}

					if !handled {
						if write_error := respondCallUnavailable(r.Context(), ws_object); write_error != nil {
							log.Printf("ошибка отправки ответа отправителю: %v", write_error)
							break readLoop
						}
					}
				}

			} else {
				log.Printf("неизвестный тип сообщения: %s", MessageType)
			}

		}

	}

}
