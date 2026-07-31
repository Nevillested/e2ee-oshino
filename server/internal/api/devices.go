package api

import (
	"encoding/base64"
	"encoding/json"
	"log"
	"net/http"
	"server/internal/db"
	"strings"

	"github.com/jackc/pgx/v5/pgtype"
)

type RegisterDeviceRequest struct {
	IdentityPubkey string `json:"identity_pubkey"` // base64
	DeviceName     string `json:"device_name"`     // опционально
}

type RegisterDeviceResponse struct {
	DeviceID string `json:"device_id"`
}

func NewRegisterDeviceHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {

		//проверяем токен
		var Session, ErrTokCheck = CheckToken(w, r, queries)

		//если с токеном проблемы - выходим и не создаем подключение по вебсокету
		if ErrTokCheck != nil {
			log.Printf("ошибка проверки токена: %v", ErrTokCheck)
			return
		}

		//объявляем переменную структуры, в которой будут лежать данные от пользователя
		var NewRegisterDeviceRequest RegisterDeviceRequest

		//объявляем переменную, которая будет декодировать из байтов в структуру NewRegisterDeviceRequest
		var NewDecoder = json.NewDecoder(r.Body)

		//декодируем JSON из байтов в структуру NewRegisterDeviceRequest, передавая в параметры указатель на структуру newRegisterRequest
		var DecodeError = NewDecoder.Decode(&NewRegisterDeviceRequest)

		//если произошла ошибка при декодировании JSON, то выводим сообщение об ошибке и возвращаем клиенту статус 400
		if DecodeError != nil {
			http.Error(w, "Ошибка декодирования JSON", http.StatusBadRequest)
			return
		}

		//переводим в байты из base64 публичный ключ
		var IdentPubKey, BaseIdentPubKeyErr = base64.StdEncoding.DecodeString(NewRegisterDeviceRequest.IdentityPubkey)

		//клиент мог прислать невалидный base64 — это 400, вина клиента
		if BaseIdentPubKeyErr != nil {
			http.Error(w, "Невалидный публичный ключ", http.StatusBadRequest)
			return
		}

		//вытаскиваем DeviceName из присланного пользователем
		var DeviceName string = NewRegisterDeviceRequest.DeviceName

		//объявляем переменную с типом не String, а TEXT постгреса. В нашей либе это разные вещи и TEXT - это отдельная структура, которую надо заполнить
		var DeviceNameStruct pgtype.Text

		//проверяем, что прислал пользователь в имени устройства и заполняем. Если пусто, то Valid - false, если нет, то true
		if len(strings.TrimSpace(DeviceName)) != 0 {
			DeviceNameStruct = pgtype.Text{String: DeviceName, Valid: true}
		} else {
			DeviceNameStruct = pgtype.Text{String: DeviceName, Valid: false}
		}

		//Создаем переменную, в которую передадим все параметры для выполнения SQL запрос
		var DeviceParams = db.CreateDeviceParams{AccountID: Session.AccountID, IdentityPubkey: IdentPubKey, DeviceName: DeviceNameStruct}

		//выполняем запрос
		var DeviceRst, SqlErr = queries.CreateDevice(r.Context(), DeviceParams)

		//проверяем есть ли ошибка при добавлении устройства
		if SqlErr != nil {
			http.Error(w, "Ошибка добавления устройства", http.StatusInternalServerError)
			return
		}

		//объявляем структуру с ответом пользователю
		var NewRegisterDeviceResponse RegisterDeviceResponse

		//в сутруктуру записываем возвращаемый DeviceId предварительно конвертируя его из UUID в String
		NewRegisterDeviceResponse.DeviceID = DeviceRst.ID.String()

		//устанавливаем тип ответа - JSON
		w.Header().Set("Content-Type", "application/json")

		//переводим наш JSON в байты и отправляем клиенту. json.NewEncoder(w).Encode(NewRegisterDeviceResponse) - это функция, которая кодирует структуру NewRegisterDeviceResponse в JSON и записывает результат в http.ResponseWriter w, который отправляет ответ клиенту.
		json.NewEncoder(w).Encode(NewRegisterDeviceResponse)

		//проверка
		/*
			curl -i -X POST http://127.0.0.1:8080/register-device \
			-H "Authorization: Bearer Ji3bJf3ODyUxumht2uvRuwSEnIbe7wZL8foFJhcxaCg=" \
			-H "Content-Type: application/json" \
			-d '{"identity_pubkey":"dGVzdGtleTEyMzQ1Njc4OTAxMjM0NTY=","device_name":"Тестовый Pixel"}'

		*/
	}
}
