package api

import (
	"encoding/base64"
	"errors"
	"log"
	"net/http"
	"server/internal/db"

	"encoding/json"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

type ResponseKeys struct {
	IdentityPubkey string `json:"identity_pubkey"`
	SignedPrekey   string `json:"signed_prekey"`
	Signature      string `json:"signature"`
	OneTimePrekey  string `json:"one_time_prekey"`
}

func NewGetPrekeyBundleHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {

	return func(w http.ResponseWriter, r *http.Request) {

		//проверяем Токен
		var _, ErrTokCheck = CheckToken(w, r, queries)

		//если с токеном проблемы - выходим и не создаем подключение по вебсокету
		if ErrTokCheck != nil {
			log.Printf("ошибка проверки токена: %v", ErrTokCheck)
			return
		}

		//достаем DeviceID из входящей http строки - это ID устройства, КОМУ хотят написать
		var deviceIDStr string = r.PathValue("device_id")

		//конвертируем DeviceID из string в необходимый постгре UUID
		var DeviceID pgtype.UUID
		ScanUuidErr := DeviceID.Scan(deviceIDStr)

		//проверяем на ошибки конечно же
		if ScanUuidErr != nil {
			http.Error(w, "Ошибка конвертации Device ID", http.StatusBadRequest)
			return
		}

		//объявляем переменную для хранения IdentityAndSignedPrekey
		var NewGetIdentityAndSignedPrekeyRow db.GetIdentityAndSignedPrekeyRow

		//получаем IdentityAndSignedPrekey ключи пользователя
		NewGetIdentityAndSignedPrekeyRow, SqlErr := queries.GetIdentityAndSignedPrekey(r.Context(), DeviceID)

		//проверяем есть ли ошибка при получении IdentityAndSignedPrekey ключей
		if SqlErr != nil {

			//проверяем что за ошибка - закончились ли ключи или у нас с базой проблема
			if errors.Is(SqlErr, pgx.ErrNoRows) {
				http.Error(w, "У получателя отсутствует SignedPrekey, попробуйте позже", http.StatusConflict)
			} else {
				http.Error(w, "Ошибка получения SignedPrekey ключей", http.StatusInternalServerError)
			}
			return
		}

		//объявляем переменную для хранения одноразовых ключей
		var NewOneTimePrekey db.OneTimePrekey

		//получаем одноразовые ключи пользователя
		NewOneTimePrekey, SqlErr = queries.ClaimOneTimePrekey(r.Context(), DeviceID)

		//проверяем есть ли ошибка при получении IdentityAndSignedPrekey ключей
		if SqlErr != nil {

			//проверяем что за ошибка - закончились ли ключи или у нас с базой проблема
			if errors.Is(SqlErr, pgx.ErrNoRows) {
				http.Error(w, "У получателя закончились одноразовые ключи, попробуйте позже", http.StatusConflict)
			} else {
				http.Error(w, "Ошибка получения одноразовых ключей", http.StatusInternalServerError)
			}
			return
		}

		//объявляем переменную для хранения ответа
		var NewResponseKeys ResponseKeys

		//заполняем ответ
		NewResponseKeys.IdentityPubkey = base64.StdEncoding.EncodeToString(NewGetIdentityAndSignedPrekeyRow.IdentityPubkey)
		NewResponseKeys.SignedPrekey = base64.StdEncoding.EncodeToString(NewGetIdentityAndSignedPrekeyRow.SignedPrekey)
		NewResponseKeys.Signature = base64.StdEncoding.EncodeToString(NewGetIdentityAndSignedPrekeyRow.Signature)
		NewResponseKeys.OneTimePrekey = base64.StdEncoding.EncodeToString(NewOneTimePrekey.Pubkey)

		//устанавливаем тип ответа - JSON
		w.Header().Set("Content-Type", "application/json")

		//переводим наш JSON в байты и отправляем клиенту. json.NewEncoder(w).Encode(NewRegisterResponse) - это функция, которая кодирует структуру NewRegisterResponse в JSON и записывает результат в http.ResponseWriter w, который отправляет ответ клиенту.
		json.NewEncoder(w).Encode(NewResponseKeys)

	}

}
