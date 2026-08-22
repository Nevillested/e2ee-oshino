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
	// Silent — служебное control-сообщение (реакция/пин/правка/удаление),
	// не самостоятельное сообщение от пользователя. Сервер не заглядывает
	// в Ciphertext и поэтому физически не может сам отличить его от
	// обычного текста — клиент помечает это открытым текстом, чтобы
	// офлайн-получателю не слался будящий push (реакция подождёт, пока он
	// сам откроет чат — будить его ради неё незачем). Само сообщение
	// всё равно встаёт в очередь и будет доставлено как обычно.
	Silent bool `json:"Silent"`
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

// WSMsgPresence — статус устройства (онлайн/офлайн + когда было видно в
// последний раз), уходит ТОЛЬКО тем, кто явно подписался через
// "presence_subscribe" (см. ConnectionRegistry.presenceSubs) — сервер не
// знает список контактов пользователя и не может разослать это всем.
type WSMsgPresence struct {
	Type         string `json:"Type"`
	FromDeviceId string `json:"FromDeviceId"`
	Online       bool   `json:"Online"`
	LastSeenMs   int64  `json:"LastSeenMs"`
}

// WSMsgTypingRelay — "печатает" от одного устройства к другому, чистый
// relay без очереди/подтверждения: неважно, если получатель не онлайн —
// печать уже наверняка закончилась к тому времени, как он подключится.
type WSMsgTypingRelay struct {
	Type         string `json:"Type"`
	FromDeviceId string `json:"FromDeviceId"`
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

// ackSender — подтверждает ОТПРАВИТЕЛЮ, что сервер принял на себя
// ответственность за его исходящее сообщение (доставил живьём или
// поставил в надёжную очередь) — симметрично уже существующему
// ack от клиента за СЕРВЕРНЫЕ отправки (см. "ack" в readLoop ниже).
// DeliveryId — клиентский, из самого входящего фрейма; если клиент его
// не прислал (старая версия / control-фрейм, который в очередь не идёт),
// просто ничего не делаем — это не ошибка, а отсутствие интереса к ack.
func ackSender(ctx context.Context, conn *websocket.Conn, deliveryID string) {
	if deliveryID == "" {
		return
	}
	// WSMsgTo не несёт DeliveryId — собираем вручную тем же способом,
	// что и остальные relay-структуры этого файла.
	var withID = struct {
		Type       string `json:"Type"`
		DeliveryId string `json:"DeliveryId"`
	}{Type: "ack", DeliveryId: deliveryID}
	msgBytes, err := json.Marshal(withID)
	if err != nil {
		return
	}
	if writeErr := conn.Write(ctx, websocket.MessageText, msgBytes); writeErr != nil {
		log.Printf("ackSender: не удалось подтвердить отправителю: %v", writeErr)
	}
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

// isPushMuted — замьючен ли этот отправитель у получателя (см. таблицу
// chat_mutes / NewMuteChatHandler). Проверяется только для обычных
// сообщений — звонки будят получателя всегда, их этот мьют не касается.
func isPushMuted(ctx context.Context, queries *db.Queries, toDeviceUUID pgtype.UUID, senderDeviceId string) bool {
	recipientInfo, err := queries.GetLoginByDeviceID(ctx, toDeviceUUID)
	if err != nil {
		return false
	}

	var senderDeviceUUID pgtype.UUID
	if err := senderDeviceUUID.Scan(senderDeviceId); err != nil {
		return false
	}
	senderInfo, err := queries.GetLoginByDeviceID(ctx, senderDeviceUUID)
	if err != nil {
		return false
	}

	muted, err := queries.IsChatMuted(ctx, db.IsChatMutedParams{
		AccountID:     recipientInfo.AccountID,
		PeerAccountID: senderInfo.AccountID,
	})
	if err != nil {
		return false
	}
	return muted
}

// isBlockedEitherWay — заблокировал ли кто-то из этой пары другого, в
// любую сторону (см. таблицу contact_blocks / NewBlockContactHandler).
// В отличие от мьюта, блокировка запрещает доставку целиком — и обычных
// сообщений, и звонков (см. вызовы ниже) — а не просто глушит push:
// клиент по своему обычному UI и так не даёт набрать сообщение
// заблокированному/блокирующему собеседнику, эта проверка — подстраховка
// на случай изменённого клиента.
func isBlockedEitherWay(ctx context.Context, queries *db.Queries, toDeviceUUID pgtype.UUID, senderDeviceId string) bool {
	recipientInfo, err := queries.GetLoginByDeviceID(ctx, toDeviceUUID)
	if err != nil {
		return false
	}

	var senderDeviceUUID pgtype.UUID
	if err := senderDeviceUUID.Scan(senderDeviceId); err != nil {
		return false
	}
	senderInfo, err := queries.GetLoginByDeviceID(ctx, senderDeviceUUID)
	if err != nil {
		return false
	}

	blocked, err := queries.IsBlockedEitherWay(ctx, db.IsBlockedEitherWayParams{
		AccountID:     recipientInfo.AccountID,
		PeerAccountID: senderInfo.AccountID,
	})
	if err != nil {
		return false
	}
	return blocked
}

// notifyPresenceSubscribers — рассылает живое обновление статуса
// deviceID всем, кто сейчас на него подписан (и сам при этом в сети —
// если подписчик не в сети, ему просто нечего писать, он всё равно не
// сможет прочитать live-обновление сейчас, а при следующем открытии чата
// заново подпишется и получит актуальный статус первым же ответом).
func notifyPresenceSubscribers(ctx context.Context, registry *ConnectionRegistry, deviceID string, online bool, lastSeenMs int64) {
	msg := WSMsgPresence{
		Type:         "presence",
		FromDeviceId: deviceID,
		Online:       online,
		LastSeenMs:   lastSeenMs,
	}
	msgBytes, err := json.Marshal(msg)
	if err != nil {
		return
	}
	for _, subscriberID := range registry.PresenceSubscribers(deviceID) {
		if conn, ok := registry.Get(subscriberID); ok {
			if writeErr := conn.Write(ctx, websocket.MessageText, msgBytes); writeErr != nil {
				log.Printf("ошибка рассылки статуса подписчику: %v", writeErr)
			}
		}
	}
}

func queuePendingMessage(ctx context.Context, queries *db.Queries, toDeviceId string, senderDeviceId string, message []byte, silent bool) {
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

	if silent {
		return
	}

	// Получатель замьютил именно этого отправителя — сообщение всё равно
	// уже лежит в очереди и придёт как обычно, когда он сам откроет
	// приложение, будить его пушем ради этого чата не нужно.
	if isPushMuted(ctx, queries, toDeviceUUID, senderDeviceId) {
		return
	}

	// Будим получателя push-ом — сам он не содержит текста сообщения,
	// только сигнал "подключись к серверу", сообщение уже лежит в
	// pending_messages и придёт по обычному зашифрованному каналу.
	if token, err := queries.GetPushTokenByDevice(ctx, toDeviceUUID); err == nil {
		push.SendDataPush(ctx, token.FcmToken, push.TypeMessage, nil)
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
		// Мы подключились — сообщаем "онлайн" всем, кто в этот момент уже
		// подписан на наш статус (например, у него открыт чат с нами и он
		// был запущен раньше нас).
		notifyPresenceSubscribers(r.Context(), registry, DeviceID, true, 0)
		defer func() {
			// RemoveIfCurrent возвращает false, если это соединение уже не
			// актуально (устройство успело переподключиться по-новой) —
			// тогда слать "офлайн" нельзя, оно по факту всё ещё онлайн.
			if !registry.RemoveIfCurrent(DeviceID, ws_object) {
				return
			}
			registry.UnsubscribeAllFor(DeviceID)

			bgCtx := context.Background()
			var deviceUUID pgtype.UUID
			if err := deviceUUID.Scan(DeviceID); err == nil {
				if err := queries.UpdateDeviceLastSeen(bgCtx, deviceUUID); err != nil {
					log.Printf("ошибка обновления last_seen: %v", err)
				}
			}
			notifyPresenceSubscribers(bgCtx, registry, DeviceID, false, time.Now().UnixMilli())
		}()

		var ToDeviceIDUUID pgtype.UUID
		ScanUuidErr := ToDeviceIDUUID.Scan(DeviceID)
		if ScanUuidErr != nil {
			log.Printf("ошибка конвертации Device ID: %v", ScanUuidErr)
			return
		}

		// Отложенные звонки доставляем первым делом, до обычных сообщений —
		// это дозвон в реальном времени, задержка тут особенно чувствуется.
		//
		// Первый кадр в очереди — всегда call_offer (см. pendingCallEntry) —
		// именно его реальную доставку подтверждаем ack'ом, как и живой
		// call_offer ниже: раньше Take() безусловно забирал и стирал запись
		// (вместе с её TTL-таймером) ДО того, как запись в сокет вообще была
		// подтверждена — при зомби-соединении звонок тихо пропадал, а
		// звонящий даже не получал "недоступен" по TTL, потому что таймер к
		// этому моменту был уже остановлен. Теперь запись остаётся в очереди
		// (и таймер тикает) до подтверждения; не дождались — она просто
		// ждёт следующего подключения или, в крайнем случае, честно
		// истекает по своему обычному TTL.
		if callID, frames, ok := pendingCalls.Peek(DeviceID); ok && len(frames) > 0 {
			var offer WSMsgFrom
			if err := json.Unmarshal(frames[0], &offer); err != nil {
				log.Printf("ошибка разбора отложенного call_offer: %v", err)
			} else {
				deliveryID := generateDeliveryID()
				relay := WSMsgRelay{
					ToDeviceId: offer.ToDeviceId,
					Ciphertext: offer.Ciphertext,
					Type:       offer.Type,
					DeliveryId: deliveryID,
				}
				relayBytes, _ := json.Marshal(relay)

				ackChan := acks.Wait(deliveryID)
				writeErr := ws_object.Write(r.Context(), websocket.MessageText, relayBytes)
				if writeErr != nil {
					log.Printf("ошибка доставки отложенного call_offer: %v", writeErr)
					acks.Cancel(deliveryID)
				} else {
					// Как и с обычными отложенными сообщениями — ждать здесь
					// синхронно нельзя, readLoop (который единственный читает
					// ack с этого соединения) ещё не запущен.
					go func() {
						select {
						case <-ackChan:
							// Подтверждено — теперь можно забрать запись
							// целиком и следом отправить уже без ожидания
							// накопившиеся буферные кадры (ICE и т.п.):
							// поодиночке они не критичны, а звонок к этому
							// моменту уже точно доставлен.
							remaining := pendingCalls.TakeIfSame(DeviceID, callID)
							if len(remaining) <= 1 {
								return
							}
							for _, frame := range remaining[1:] {
								if err := ws_object.Write(context.Background(), websocket.MessageText, frame); err != nil {
									log.Printf("ошибка доставки буферного кадра звонка: %v", err)
									break
								}
							}
						case <-time.After(5 * time.Second):
							acks.Cancel(deliveryID)
							log.Printf("получатель не подтвердил отложенный call_offer за 5с, оставляем в очереди")
						}
					}()
				}
			}
		}

		var PendingMessages []db.PendingMessage
		PendingMessages, SqlErr := queries.GetPendingMessages(r.Context(), ToDeviceIDUUID)
		if SqlErr != nil {
			log.Printf("ошибка получения сообщений из бд: %v", SqlErr)
		} else {
			// Каждое отложенное сообщение уходит с собственным DeliveryId и
			// удаляется из очереди ТОЛЬКО после ack от клиента — раньше вся
			// пачка стиралась из pending_messages сразу после записи в сокет,
			// не дожидаясь вообще никакого подтверждения (в отличие от живой
			// доставки чуть ниже, у которой ack уже был). Любой сбой между
			// "сервер записал в сокет" и "клиент успел расшифровать и
			// сохранить" (обрыв сети сразу после реконнекта, ОС прибила
			// процесс на середине и т.п.) означал безвозвратную потерю
			// сообщения. Теперь неподтверждённые просто остаются в очереди
			// до следующего подключения — безопасно: клиент и так должен
			// уметь игнорировать повторно пришедшее сообщение по message_id.
			for _, msg := range PendingMessages {
				var parsed WSMsgFrom
				if err := json.Unmarshal([]byte(msg.Ciphertext), &parsed); err != nil {
					log.Printf("ошибка разбора отложенного сообщения: %v", err)
					continue
				}

				deliveryID := generateDeliveryID()
				relay := WSMsgRelay{
					ToDeviceId: parsed.ToDeviceId,
					Ciphertext: parsed.Ciphertext,
					Type:       parsed.Type,
					DeliveryId: deliveryID,
				}
				relayBytes, _ := json.Marshal(relay)

				ackChan := acks.Wait(deliveryID)
				writeErr := ws_object.Write(r.Context(), websocket.MessageText, relayBytes)
				if writeErr != nil {
					log.Printf("ошибка отправки отложенного сообщения: %v", writeErr)
					acks.Cancel(deliveryID)
					continue
				}

				// Само чтение ack идёт из readLoop ниже (он стартует сразу
				// после этого цикла) — ждать здесь синхронно нельзя, до
				// readLoop сокет никто не читает, ack физически не может
				// прийти. Поэтому ждём в фоне, не блокируя вход в readLoop.
				msgID := msg.ID
				go func() {
					select {
					case <-ackChan:
						if err := queries.DeletePendingMessage(context.Background(), msgID); err != nil {
							log.Printf("ошибка удаления доставленного отложенного сообщения: %v", err)
						}
					case <-time.After(5 * time.Second):
						acks.Cancel(deliveryID)
					}
				}()
			}
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

			if MessageType == "presence_subscribe" {
				// Отвечаем СРАЗУ текущим статусом (а не ждём следующего
				// изменения) — иначе открывший чат экран мгновение
				// показывал бы "нет данных" вместо реального статуса.
				online := registry.SubscribePresence(DeviceID, NewWSMsgFrom.ToDeviceId)
				var lastSeenMs int64
				if !online {
					var targetUUID pgtype.UUID
					if err := targetUUID.Scan(NewWSMsgFrom.ToDeviceId); err == nil {
						if lastSeen, err := queries.GetDeviceLastSeen(r.Context(), targetUUID); err == nil && lastSeen.Valid {
							lastSeenMs = lastSeen.Time.UnixMilli()
						}
					}
				}
				msg := WSMsgPresence{
					Type:         "presence",
					FromDeviceId: NewWSMsgFrom.ToDeviceId,
					Online:       online,
					LastSeenMs:   lastSeenMs,
				}
				if msgBytes, err := json.Marshal(msg); err == nil {
					if err := ws_object.Write(r.Context(), message_type, msgBytes); err != nil {
						log.Printf("ошибка ответа на подписку на статус: %v", err)
					}
				}
				continue
			}

			if MessageType == "presence_unsubscribe" {
				registry.UnsubscribePresence(DeviceID, NewWSMsgFrom.ToDeviceId)
				continue
			}

			if MessageType == "typing" {
				// Чистый relay без очереди и подтверждения — офлайн-получателю
				// это уже неактуально к моменту, когда он подключится.
				if conn, ok := registry.Get(NewWSMsgFrom.ToDeviceId); ok {
					typingMsg := WSMsgTypingRelay{Type: "typing", FromDeviceId: DeviceID}
					if msgBytes, err := json.Marshal(typingMsg); err == nil {
						if err := conn.Write(r.Context(), message_type, msgBytes); err != nil {
							log.Printf("ошибка пересылки статуса печати: %v", err)
						}
					}
				}
				continue
			}

			var ConnReceiver, Status = registry.Get(NewWSMsgFrom.ToDeviceId)

			if MessageType == "message" {

				var toDeviceUUIDForBlockCheck pgtype.UUID
				ScanErr := toDeviceUUIDForBlockCheck.Scan(NewWSMsgFrom.ToDeviceId)
				if ScanErr == nil &&
					isBlockedEitherWay(r.Context(), queries, toDeviceUUIDForBlockCheck, DeviceID) {
					// Заблокировано в любую сторону — ни доставлять, ни ставить в
					// очередь: обычный клиент и так не даёт набрать сообщение
					// (см. композер-заглушку в chat_screen.dart), это подстраховка
					// на случай изменённого клиента.
					continue
				}

				// Первый обмен сообщением между двумя аккаунтами — источник
				// записи в contacts (см. 018_contacts.sql): сервер раньше вообще
				// не знал "кто с кем переписывается", это нужно для приватности
				// профиля (уровень "только контакты") и прицельной доставки
				// profile_updated. ON CONFLICT DO NOTHING — дёшево звать на
				// каждое сообщение, не только на первое.
				if ScanErr == nil {
					if recipientInfo, err := queries.GetLoginByDeviceID(r.Context(), toDeviceUUIDForBlockCheck); err == nil {
						var senderDeviceUUID pgtype.UUID
						if err := senderDeviceUUID.Scan(DeviceID); err == nil {
							if senderInfo, err := queries.GetLoginByDeviceID(r.Context(), senderDeviceUUID); err == nil {
								if err := queries.UpsertContactsPair(r.Context(), db.UpsertContactsPairParams{
									AccountID:     senderInfo.AccountID,
									PeerAccountID: recipientInfo.AccountID,
								}); err != nil {
									log.Printf("ошибка записи в contacts: %v", err)
								}
							}
						}
					}
				}

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
						queuePendingMessage(r.Context(), queries, NewWSMsgFrom.ToDeviceId, DeviceID, message, NewWSMsgFrom.Silent)
						ackSender(r.Context(), ws_object, NewWSMsgFrom.DeliveryId)
						continue
					}

					select {
					case <-ackChan:

					case <-time.After(5 * time.Second):
						log.Printf("получатель не подтвердил доставку за 5с, ставим в очередь")
						acks.Cancel(deliveryID)
						registry.RemoveIfCurrent(NewWSMsgFrom.ToDeviceId, ConnReceiver)
						queuePendingMessage(r.Context(), queries, NewWSMsgFrom.ToDeviceId, DeviceID, message, NewWSMsgFrom.Silent)
					}
					// В обоих случаях (доставлено живьём или поставлено в
					// очередь) сервер принял на себя ответственность за
					// сообщение — сообщаем ОТПРАВИТЕЛЮ (см. ackSender): это
					// основа единой клиентской очереди отправки, раньше
					// подтверждения в эту сторону не было вообще.
					ackSender(r.Context(), ws_object, NewWSMsgFrom.DeliveryId)

				} else {
					log.Printf("Сообщение поставлено в очередь до тех пор, пока устройство не будет в сети")
					queuePendingMessage(r.Context(), queries, NewWSMsgFrom.ToDeviceId, DeviceID, message, NewWSMsgFrom.Silent)
					ackSender(r.Context(), ws_object, NewWSMsgFrom.DeliveryId)
				}

			} else if MessageType == "call_offer" {

				var toDeviceUUIDForBlockCheck pgtype.UUID
				if err := toDeviceUUIDForBlockCheck.Scan(NewWSMsgFrom.ToDeviceId); err == nil &&
					isBlockedEitherWay(r.Context(), queries, toDeviceUUIDForBlockCheck, DeviceID) {
					// Заблокировано в любую сторону — звонок не проходит вообще,
					// ни живьём, ни отложенным дозвоном: отвечаем отправителю так
					// же, как если бы получатель был недоступен.
					if write_error := respondCallUnavailable(r.Context(), ws_object); write_error != nil {
						log.Printf("ошибка отправки ответа отправителю: %v", write_error)
						break readLoop
					}
					continue
				}

				// call_offer — единственный кадр звонка, чья тихая потеря
				// фатальна: без него звонок просто никогда не зазвонит, без
				// единого сигнала кому-либо. Поэтому даже если получатель
				// формально "в сети" (Status == true), одной успешной записи
				// в сокет недостаточно — соединение может быть зомби (TCP ещё
				// жив, но Android в фоне/Doze уже не доставляет по нему
				// пакеты). Требуем настоящее подтверждение (ack) от клиента,
				// как и для обычных сообщений; не дождались — считаем
				// получателя офлайн и уходим в очередь отложенных звонков + push,
				// точно так же, как для честно отключённого получателя.
				var callPayload CallSignalPayload
				_ = json.Unmarshal([]byte(NewWSMsgFrom.Ciphertext), &callPayload)

				delivered := false

				if Status == true {
					deliveryID := generateDeliveryID()
					relay := WSMsgRelay{
						ToDeviceId: NewWSMsgFrom.ToDeviceId,
						Ciphertext: NewWSMsgFrom.Ciphertext,
						Type:       MessageType,
						DeliveryId: deliveryID,
					}
					relayBytes, _ := json.Marshal(relay)

					ackChan := acks.Wait(deliveryID)
					write_error := ConnReceiver.Write(r.Context(), message_type, relayBytes)

					if write_error != nil {
						log.Printf("получатель считался онлайн, но запись звонка не удалась (зомби-соединение): %v", write_error)
						acks.Cancel(deliveryID)
						registry.RemoveIfCurrent(NewWSMsgFrom.ToDeviceId, ConnReceiver)
					} else {
						select {
						case <-ackChan:
							delivered = true
						case <-time.After(5 * time.Second):
							log.Printf("получатель не подтвердил звонок за 5с, считаем офлайн (зомби-соединение)")
							acks.Cancel(deliveryID)
							registry.RemoveIfCurrent(NewWSMsgFrom.ToDeviceId, ConnReceiver)
						}
					}
				}

				if !delivered {
					if callPayload.CallID == "" {
						if write_error := respondCallUnavailable(r.Context(), ws_object); write_error != nil {
							log.Printf("ошибка отправки ответа отправителю: %v", write_error)
							break readLoop
						}
					} else {
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
								// caller_device_id — тот же класс данных, что и call_id: непрозрачный
								// UUID, ничего не раскрывающий без отдельного авторизованного запроса
								// (см. GetDeviceOwnerInfo на клиенте). Нужен нативной стороне клиента
								// (CallDeclineReceiver), чтобы при отклонении звонка из полностью
								// закрытого приложения было о ком записать пропущенный звонок в
								// локальную историю чата при следующем запуске.
								push.SendDataPush(r.Context(), token.FcmToken, push.TypeCall, map[string]string{
									"call_id":          callID,
									"caller_device_id": DeviceID,
								})
							}
						}
					}
				}

			} else if strings.HasPrefix(MessageType, "call_") {

				if Status == true {
					var write_error = ConnReceiver.Write(r.Context(), message_type, message)
					if write_error != nil {
						// write_error — про соединение ПОЛУЧАТЕЛЯ (ConnReceiver),
						// а не отправителя (это же соединение, чей readLoop
						// сейчас выполняется) — break readLoop здесь обрывал бы
						// СВОЁ, рабочее соединение из-за чужого зомби-сокета.
						// Чистим стухший реестр получателя и просто идём дальше
						// читать следующий кадр отправителя.
						log.Printf("ошибка доставки %s получателю (зомби-соединение): %v", MessageType, write_error)
						registry.RemoveIfCurrent(NewWSMsgFrom.ToDeviceId, ConnReceiver)
					}
				} else {
					var callPayload CallSignalPayload
					_ = json.Unmarshal([]byte(NewWSMsgFrom.Ciphertext), &callPayload)

					var handled bool

					switch MessageType {
					case "call_cancel", "call_end", "call_reject", "call_busy":
						if pendingCalls.Cancel(NewWSMsgFrom.ToDeviceId, callPayload.CallID, DeviceID) {
							handled = true

							// Получатель мог уже звонить нативным
							// foreground-service (см. TypeCall) — не
							// дожидаясь TTL, просим его остановиться прямо
							// сейчас.
							var toDeviceUUID pgtype.UUID
							if uuidErr := toDeviceUUID.Scan(NewWSMsgFrom.ToDeviceId); uuidErr == nil {
								if token, err := queries.GetPushTokenByDevice(r.Context(), toDeviceUUID); err == nil {
									push.SendDataPush(r.Context(), token.FcmToken, push.TypeCallCancel, nil)
								}
							}
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
