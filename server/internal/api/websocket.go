package api

import (
	"log"
	"net/http"
	"server/internal/db"

	"encoding/base64"

	"crypto/sha256"
	"strings"

	"time"

	"github.com/coder/websocket"
	"github.com/jackc/pgx/v5/pgtype"
)

/*
функция NewWebSocketHandler принимает 1 параметр queries с типом *db.Queries
функция NewWebSocketHandler возвращает функцию с типом func(http.ResponseWriter, *http.Request),
где w - это данные(канал) от сервера к клиенту, r - это данные от клиента к серверу
*/
func NewWebSocketHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {

	return func(w http.ResponseWriter, r *http.Request) {

		//получаем заголовок
		var NewAuthorization = r.Header.Get("Authorization")

		//проверяем, не пустой ли заголовок
		if len(NewAuthorization) == 0 {
			http.Error(w, "Ошибка заголовка вебсокета", http.StatusUnauthorized)
			return
		}

		//Из заголовка удаляем "Bearer " чтобы оставить только токен
		var token string = strings.TrimPrefix(NewAuthorization, "Bearer ")

		//формируем хэш токен по sha256
		var hashArray [32]byte = sha256.Sum256([]byte(token))
		var tokenHash string = base64.StdEncoding.EncodeToString(hashArray[:])

		//лезем в бд и по хэшу токена ищем там данные пользователя
		var Session, SessionErr = queries.GetValidSessionByToken(r.Context(), tokenHash)

		//проверяем есть ли валидные сессии или нет
		if SessionErr != nil {
			http.Error(w, "Нет валидных сессий", http.StatusUnauthorized)
			return
		}

		//устанавливаем новую дату жизни токена. 30 дней от текущего момента
		var NewDtExpiries = pgtype.Timestamptz{Time: time.Now().Add(30 * 24 * time.Hour), InfinityModifier: pgtype.Finite, Valid: true}

		//продлеваем жизнь токену, под которым вошел пользователь
		var ExSessionError = queries.ExtendSession(r.Context(), db.ExtendSessionParams{ID: Session.ID, ExpiresAt: NewDtExpiries})

		//проверяем продлена ли жизнь токена
		if ExSessionError != nil {
			log.Printf("не удалось продлить сессию: %v", ExSessionError)
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

		//держим вебсокет в цикле постоянно открытым
		for {
			//читаем данные из вебсокета
			var message_type, message, read_error = ws_object.Read(r.Context())

			//если произошла ошибка при чтении сообщения, то выводим сообщение об ошибке и выходим из цикла
			if read_error != nil {
				log.Printf("ошибка чтения сообщения из вебсокета: %v", read_error)
				break
			}

			//выводим в лог сообщение, которое пришло от клиента
			log.Printf("получено сообщение от клиента: %s", message)

			//отправляем обратно клиенту то же самое сообщение, которое пришло от него (эхо-сервер)
			var write_error = ws_object.Write(r.Context(), message_type, message)

			//если произошла ошибка при отправке сообщения, то выводим сообщение об ошибке и выходим из цикла
			if write_error != nil {
				log.Printf("ошибка отправки сообщения в вебсокет: %v", write_error)
				break
			}
		}

	}

}
