package api

import (
	"encoding/json"
	"net/http"
	"server/internal/db"

	"github.com/pquerna/otp/totp"
)

type VerifyTOTPRequest struct {
	Login string `json:"login"`
	Code  string `json:"code"`
}

func NewVerifyTOTPHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {

		//объявляем переменную, где будут храниться данные логина и кода TOTP, которые пришли от клиента в JSON-формате
		var NewDataFromClient VerifyTOTPRequest

		//объявляем переменную, которая будет декодировать из байтов в структуру RegisterRequest
		var NewDecoder = json.NewDecoder(r.Body)

		//переводим из байтового вида и записываем в созданный экземпляр
		var DecodeError = NewDecoder.Decode(&NewDataFromClient)

		//если произошла ошибка при декодировании JSON, то выводим сообщение об ошибке и возвращаем клиенту статус 500
		if DecodeError != nil {
			http.Error(w, "Ошибка декодирования JSON", http.StatusBadRequest)
			return
		}

		//делаем запрос к бд, передавая в качестве параметра логин, который пришел от клиента. В ответ получаем структуру Account, которая содержит все данные аккаунта, включая секретный ключ TOTP, который сохранили на этапе регистрации
		var account, SqlError = queries.GetAccountByLogin(r.Context(), NewDataFromClient.Login)

		//проверяем ошибки, при запросе к бд, если есть, даем пользотваелю ответ со статусом 500
		if SqlError != nil {
			http.Error(w, "Ошибка поиска пользователя", http.StatusInternalServerError)
			return
		}

		//переменная для хранения секрета аутентификатор
		var UserSecret string = account.TotpSecret

		//переменная для хранения полученного кода от пользователя
		var UserCode string = NewDataFromClient.Code

		//проверяем код
		var CheckResult bool = totp.Validate(UserCode, UserSecret)

		//отправляем результат
		if CheckResult {
			w.WriteHeader(http.StatusOK)
		} else {
			http.Error(w, "Неверный код", http.StatusUnauthorized)
		}

		//проверка регистрация ч.1
		//curl -X POST http://127.0.0.1:8080/register -H "Content-Type: application/json" -d '{"login":"alice","password":"supersecret123"}'
		//проверка регистрация ч.2
		//curl -X POST http://127.0.0.1:8080/verify-totp -H "Content-Type: application/json" -d '{"login":"alice","code":"123456"}'

	}
}
