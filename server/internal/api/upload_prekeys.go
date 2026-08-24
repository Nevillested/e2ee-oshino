package api

import (
	"encoding/json"
	"log"
	"net/http"
	"server/internal/db"

	"encoding/base64"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

type UploadPrekeysRequest struct {
	DeviceID              string   `json:"device_id"`               // uuid устройства, к которому привязываем
	SignedPrekey          string   `json:"signed_prekey"`           // base64
	SignedPrekeySignature string   `json:"signed_prekey_signature"` // base64
	OneTimePrekeys        []string `json:"one_time_prekeys"`        // массив base64-строк
}

func NewUploadPrekeysHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {

	return func(w http.ResponseWriter, r *http.Request) {

		//проверяем Токен
		var Session, ErrTokCheck = CheckToken(w, r, queries)

		//если с токеном проблемы - выходим и не создаем подключение по вебсокету
		if ErrTokCheck != nil {
			log.Printf("ошибка проверки токена: %v", ErrTokCheck)
			return
		}

		//объявляем переменную, где будут храниться данные по сгенерированным ключам от клиента
		var NewUploadPrekeysRequest UploadPrekeysRequest

		//объявляем переменную, которая будет декодировать из байтов в структуру NewUploadPrekeysRequest
		var NewDecoder = json.NewDecoder(r.Body)

		//переводим из байтового вида и записываем в созданный экземпляр
		var DecodeError = NewDecoder.Decode(&NewUploadPrekeysRequest)

		//если произошла ошибка при декодировании JSON, то выводим сообщение об ошибке и возвращаем клиенту статус 500
		if DecodeError != nil {
			http.Error(w, "Ошибка декодирования JSON", http.StatusBadRequest)
			return
		}

		//конвертируем из прилетевшего формата string в необходимый постгре UUID
		var DeviceID pgtype.UUID
		ScanUuidErr := DeviceID.Scan(NewUploadPrekeysRequest.DeviceID)

		//проверяем на ошибки конечно же
		if ScanUuidErr != nil {
			http.Error(w, "Ошибка конвертации Device ID", http.StatusBadRequest)
			return
		}

		var owner, OwnerErr = queries.GetLoginByDeviceID(r.Context(), DeviceID)
		if OwnerErr != nil {
			if OwnerErr == pgx.ErrNoRows {
				http.Error(w, "Устройство не найдено", http.StatusNotFound)
			} else {
				http.Error(w, "Ошибка проверки владельца устройства", http.StatusInternalServerError)
			}
			return
		}
		if owner.AccountID != Session.AccountID {
			http.Error(w, "Устройство принадлежит другому аккаунту", http.StatusForbidden)
			return
		}

		//переводим SignedPrekey из base64 в байты
		var SignedPrekey, SignedPrekeyErr = base64.StdEncoding.DecodeString(NewUploadPrekeysRequest.SignedPrekey)

		//клиент мог прислать невалидный base64 — это 400, вина клиента
		if SignedPrekeyErr != nil {
			http.Error(w, "Невалидный SignedPrekey", http.StatusBadRequest)
			return
		}

		//переводим SignedPrekeySignature из base64 в байты
		var SignedPrekeySignature, SignedPrekeySignatureErr = base64.StdEncoding.DecodeString(NewUploadPrekeysRequest.SignedPrekeySignature)

		//клиент мог прислать невалидный base64 — это 400, вина клиента
		if SignedPrekeySignatureErr != nil {
			http.Error(w, "Невалидный SignedPrekeySignature", http.StatusBadRequest)
			return
		}

		//вставляем в бд SignedPrekey, SignedPrekeySignature для указанного DeviceID
		var _, SqlErr = queries.UpsertSignedPrekey(r.Context(), db.UpsertSignedPrekeyParams{DeviceID: DeviceID, Pubkey: SignedPrekey, Signature: SignedPrekeySignature})

		//проверяем есть ли ошибка при добавлении SignedPrekey
		if SqlErr != nil {
			http.Error(w, "Ошибка добавления SignedPrekey", http.StatusInternalServerError)
			return
		}

		//забираем одноразовые ключи
		var OneTimePrekeys []string = NewUploadPrekeysRequest.OneTimePrekeys

		var pubkeysBytes [][]byte

		//пройтись по всем ключам и перевести их из base64 в байты
		for _, oneKeyBase64 := range OneTimePrekeys {
			decoded, err := base64.StdEncoding.DecodeString(oneKeyBase64)
			if err != nil {
				http.Error(w, "Невалидный one-time prekey", http.StatusBadRequest)
				return
			}
			pubkeysBytes = append(pubkeysBytes, decoded)
		}

		var NewCreateOneTimePrekeysParams = db.CreateOneTimePrekeysParams{DeviceID: DeviceID, Pubkeys: pubkeysBytes}

		_, SqlErr = queries.CreateOneTimePrekeys(r.Context(), NewCreateOneTimePrekeysParams)

		//проверяем есть ли ошибка при добавлении OneTimePrekeys
		if SqlErr != nil {
			http.Error(w, "Ошибка добавления OneTimePrekeys", http.StatusInternalServerError)
			return
		}

		//даем ответ, что все ок
		w.WriteHeader(http.StatusOK)

	}

}
