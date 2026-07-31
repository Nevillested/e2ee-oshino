package api

import (
	"encoding/json"
	"log"
	"net/http"
	"server/internal/db"

	"github.com/coder/websocket"
	"github.com/jackc/pgx/v5/pgtype"
)

type WSMessage struct {
	ToDeviceId string `json:"ToDeviceId"`
	Ciphertext string `json:"Ciphertext"`
}

/*
функция NewWebSocketHandler принимает 1 параметр queries с типом *db.Queries
функция NewWebSocketHandler возвращает функцию с типом func(http.ResponseWriter, *http.Request),
где w - это данные(канал) от сервера к клиенту, r - это данные от клиента к серверу
*/
func NewWebSocketHandler(queries *db.Queries, registry *ConnectionRegistry) func(http.ResponseWriter, *http.Request) {

	return func(w http.ResponseWriter, r *http.Request) {

		//проверяем Токен
		var _, ErrTokCheck = CheckToken(w, r, queries)
		//var Session, ErrTokCheck = CheckToken(w, r, queries)

		//если с токеном проблемы - выходим и не создаем подключение по вебсокету
		if ErrTokCheck != nil {
			log.Printf("ошибка проверки токена: %v", ErrTokCheck)
			return
		}

		//открытие соединения вебсокета upgrade из http в websocket
		var ws_object, ws_error = websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})

		//не выходим из программы совсем, как в случае с сервером, а только закрываем вебсокет-соединение и продолжаем работу
		if ws_error != nil {
			log.Printf("ошибка создания вебсокета: %v", ws_error)
			return
		}

		//закрытие соединения вебсокета ПОСЛЕ того, как wsHandler завершит свою работу
		//defer - это ключевое слово, которое откладывает выполнение функции до тех пор, пока не завершится выполнение функции, где был написан defer
		defer ws_object.CloseNow()

		//раз установлено веб-сокет подключение, мы должны передать в наш справочник инфу, что текущий пользователь - подключен
		//для начала заберем ID устройства, который сейчас подключен. Он находится в URL строке, передаваемой с клиента
		var DeviceID string = r.URL.Query().Get("device_id")

		//добавим само устройство в список подключенных к серверу
		registry.Add(DeviceID, ws_object)

		//заранее определим удаление текущего устройства из списка подключенных, когда текущая функция завершится
		defer registry.Remove(DeviceID)

		//-------------------------------------------------------------------------------------------------------------------------------------
		//Сразу после добавления устройства в сисок подключенных надо забрать все сообщения от сервера, которые накопились, для этого:
		//1) Необходимо выполнить queries.GetPendingMessages - оно на вход принимает контекст и Device ID в постгресовском формате UUID.
		//   Получается надо DeviceID конвертировать из имеющейся string в UUID. Для начала создадим переменную с таким типом:
		var ToDeviceIDUUID pgtype.UUID

		//2) Конвертируем Divce ID из String в UUID
		ScanUuidErr := ToDeviceIDUUID.Scan(DeviceID)

		//3) Проверяем на ошибки конвертации
		if ScanUuidErr != nil {
			log.Printf("ошибка конвертации Device ID: %v", ScanUuidErr)
			return
		}

		//4) объявляем переменную, куда сложим все накопившиеся сообщения, предназначенные этому устройству
		var PendingMessages []db.PendingMessage

		//5) забираем все накопленные сообщения, которые предназначлись этому устройству
		PendingMessages, SqlErr := queries.GetPendingMessages(r.Context(), ToDeviceIDUUID)

		//6) проверяем ошибку работы бд
		if SqlErr != nil {

			//6.1) если ошибка есть - логируемся
			log.Printf("ошибка получения сообщений из бд: %v", SqlErr)

		} else {

			//6.2) если ошибки нет, то в цикле...
			for _, msg := range PendingMessages {

				//отправляем все сообщения
				var err = ws_object.Write(r.Context(), websocket.MessageText, []byte(msg.Ciphertext))

				//и проверяем ошибку, если есть - логируемся
				if err != nil {
					log.Printf("ошибка отправки сообщения: %v", err)
				}

			}

		}

		//7) Удаляем все отправленные сообщения
		SqlErr = queries.DeletePendingMessages(r.Context(), ToDeviceIDUUID)

		//8) проверяем ошибку работы бд
		if SqlErr != nil {

			//6.1) если ошибка есть - логируемся
			log.Printf("ошибка удаления сообщений в бд: %v", SqlErr)

			return

		}
		//-------------------------------------------------------------------------------------------------------------------------------------

		//держим вебсокет в цикле постоянно открытым
		for {
			//читаем данные из вебсокета
			var message_type, message, read_error = ws_object.Read(r.Context())

			//если произошла ошибка при чтении сообщения, то выводим сообщение об ошибке и выходим из цикла
			if read_error != nil {
				log.Printf("ошибка чтения сообщения из вебсокета: %v", read_error)
				break
			}

			//создаем переменную, в которой будем хранить кому предназначено сообщение и само сообщений
			var NewMessage WSMessage

			//объявляем переменную, которая будет декодировать из байтов в NewMessage (JSON)
			var DecodeError = json.Unmarshal(message, &NewMessage)

			//если произошла ошибка, то переходим к чтению следующего сообщения
			if DecodeError != nil {
				log.Printf("ошибка декодирования сообщения: %v", DecodeError)
				continue
			}

			//проверяем подключено ли сейчас к серверу то устройство, куда предназначается сообщение
			var ConnReceiver, Status = registry.Get(NewMessage.ToDeviceId)

			if Status == true { //если подключено, то сразу отправляем подключенному к серверу устройству сообщение

				//отправляем клиенту предназначающеееся сообщение, которое пришло от кого-то
				var write_error = ConnReceiver.Write(r.Context(), message_type, message)

				//если произошла ошибка при отправке сообщения, то выводим сообщение об ошибке и выходим из цикла
				if write_error != nil {
					log.Printf("ошибка отправки сообщения в вебсокет: %v", write_error)
					break
				}

			} else { //если не подключено ставим сообщение в очередь до тех пор, пока устройство не подключится

				log.Printf("Сообщение поставлено в очередь до тех пор, пока устройство не будет в сети")

				//объявляем переменную, где будут храниться необходимые данные для передачи сообщения в очередь бд - на ожидание
				var NewSavePendingMessage db.SavePendingMessageParams

				//в постгре мы будем хранить Device ID в поле с типом UUID, поэтому нужно для начала конвертировать...
				var ToDeviceIDUUID pgtype.UUID

				//...конвертировать из String в UUID
				ScanUuidErr := ToDeviceIDUUID.Scan(NewMessage.ToDeviceId)

				//проверить на ошибки конвертации
				if ScanUuidErr != nil {
					log.Printf("Ошибка конвертации Device ID: %v", ScanUuidErr)
					continue
				}

				//заполнить переменную данными (в этой переменной лежат параметры для вставки в таблицу очереди сообщений)
				NewSavePendingMessage.ToDeviceID = ToDeviceIDUUID
				NewSavePendingMessage.Ciphertext = string(message)

				//вставить сообщение в таблицу ожидания (ожидание подключение клиента к серверу)
				var SqlErr = queries.SavePendingMessage(r.Context(), NewSavePendingMessage)

				//проверить на ошибки вставки
				if SqlErr != nil {
					log.Printf("Ошибка добавления сообщения в очередь: %v", SqlErr)
					continue
				}

			}

		}

	}

}
