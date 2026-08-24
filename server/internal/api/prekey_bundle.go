package api

import (
	"encoding/base64"
	"errors"
	"log"
	"net/http"
	"server/internal/db"
	"time"

	"encoding/json"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

// prekeyBundleLimiter — раньше этот эндпоинт был вообще без лимита: любой
// залогиненный аккаунт мог сколько угодно раз подряд запрашивать бандл
// одного и того же чужого устройства, каждый раз безвозвратно забирая один
// одноразовый prekey из его пула (см. ClaimOneTimePrekey) — что само по
// себе теперь не фатально (см. fallback ниже на пустой пул), но всё равно
// стоит не давать искусственно ускорять исчерпание чужого пула впустую.
// Ключ — requester+target, а не просто IP: обычная переписка с НЕСКОЛЬКИМИ
// разными людьми не должна упираться в лимит, ломиться в ОДНОГО и того же
// человека — должна.
var prekeyBundleLimiter = NewRateLimiter(time.Minute, 10)

type ResponseKeys struct {
	AccountID           string  `json:"account_id"`
	IdentityPubkey      string  `json:"identity_pubkey"`
	IdentityDhPubkey    string  `json:"identity_dh_pubkey"`
	IdentityDhSignature string  `json:"identity_dh_signature"`
	SignedPrekey        string  `json:"signed_prekey"`
	Signature           string  `json:"signature"`
	// nil (опущено из JSON, см. omitempty) — если у получателя закончились
	// одноразовые prekeys, см. комментарий у ClaimOneTimePrekey ниже.
	// client/lib/crypto/x3dh.dart уже готов к отсутствию этого поля.
	OneTimePrekey *string `json:"one_time_prekey,omitempty"`
}

func NewGetPrekeyBundleHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {

	return func(w http.ResponseWriter, r *http.Request) {

		//проверяем Токен
		var Session, ErrTokCheck = CheckToken(w, r, queries)

		//если с токеном проблемы - выходим и не создаем подключение по вебсокету
		if ErrTokCheck != nil {
			log.Printf("ошибка проверки токена: %v", ErrTokCheck)
			return
		}

		//достаем DeviceID из входящей http строки - это ID устройства, КОМУ хотят написать
		var deviceIDStr string = r.PathValue("device_id")

		var limiterKey = Session.AccountID.String() + "|" + deviceIDStr
		if !prekeyBundleLimiter.Allowed(limiterKey) {
			http.Error(w, "Слишком много запросов бандла для этого устройства, попробуйте позже", http.StatusTooManyRequests)
			return
		}
		prekeyBundleLimiter.RecordFailure(limiterKey)

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

		//получаем одноразовые ключи пользователя
		NewOneTimePrekey, OtpErr := queries.ClaimOneTimePrekey(r.Context(), DeviceID)

		//одноразовый ключ — необязательная часть бандла. Раньше пустой пул
		// (ErrNoRows) заваливал ВСЮ выдачу бандла 409-й ошибкой — новую
		// переписку с этим человеком нельзя было начать вообще, пока он не
		// зайдёт в сеть и prekey_replenisher.dart сам не пополнит пул.
		// X3DH прекрасно работает и без четвёртого DH (см.
		// client/lib/crypto/x3dh.dart — establishOutgoingRoot уже
		// обрабатывает one_time_prekey == null), просто без дополнительной
		// forward secrecy у самого первого сообщения — гораздо лучше, чем
		// вообще не суметь написать человеку.
		var oneTimePrekeyB64 *string
		if OtpErr != nil {
			if errors.Is(OtpErr, pgx.ErrNoRows) {
				oneTimePrekeyB64 = nil
			} else {
				http.Error(w, "Ошибка получения одноразовых ключей", http.StatusInternalServerError)
				return
			}
		} else {
			encoded := base64.StdEncoding.EncodeToString(NewOneTimePrekey.Pubkey)
			oneTimePrekeyB64 = &encoded
		}

		//объявляем переменную для хранения ответа
		var NewResponseKeys ResponseKeys

		//заполняем ответ
		NewResponseKeys.IdentityPubkey = base64.StdEncoding.EncodeToString(NewGetIdentityAndSignedPrekeyRow.IdentityPubkey)
		NewResponseKeys.IdentityDhPubkey = base64.StdEncoding.EncodeToString(NewGetIdentityAndSignedPrekeyRow.IdentityDhPubkey)
		NewResponseKeys.IdentityDhSignature = base64.StdEncoding.EncodeToString(NewGetIdentityAndSignedPrekeyRow.IdentityDhSignature)
		NewResponseKeys.SignedPrekey = base64.StdEncoding.EncodeToString(NewGetIdentityAndSignedPrekeyRow.SignedPrekey)
		NewResponseKeys.Signature = base64.StdEncoding.EncodeToString(NewGetIdentityAndSignedPrekeyRow.Signature)
		NewResponseKeys.OneTimePrekey = oneTimePrekeyB64
		NewResponseKeys.AccountID = NewGetIdentityAndSignedPrekeyRow.AccountID.String()

		//устанавливаем тип ответа - JSON
		w.Header().Set("Content-Type", "application/json")

		//переводим наш JSON в байты и отправляем клиенту. json.NewEncoder(w).Encode(NewRegisterResponse) - это функция, которая кодирует структуру NewRegisterResponse в JSON и записывает результат в http.ResponseWriter w, который отправляет ответ клиенту.
		json.NewEncoder(w).Encode(NewResponseKeys)

	}

}
