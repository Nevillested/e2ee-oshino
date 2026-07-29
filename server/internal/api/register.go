package api

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"log"
	"net/http"
	"server/internal/db"

	"github.com/pquerna/otp/totp"
	"golang.org/x/crypto/argon2"
)

type RegisterRequest struct {
	Login    string `json:"login"`
	Password string `json:"password"`
}

type RegisterResponse struct {
	TotpURL string `json:"totp_url"`
}

func NewRegisterHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {

		//объявляем переменную, где будут храниться данные запроса на регистрацию
		var newRegisterRequest RegisterRequest

		//объявляем переменную, которая будет декодировать из байтов в структуру RegisterRequest
		var NewDecoder = json.NewDecoder(r.Body)

		//декодируем JSON из байтов в структуру RegisterRequest, передавая в параметры указатель на структуру newRegisterRequest
		var DecodeError = NewDecoder.Decode(&newRegisterRequest)

		//если произошла ошибка при декодировании JSON, то выводим сообщение об ошибке и возвращаем клиенту статус 500
		if DecodeError != nil {
			http.Error(w, "Ошибка декодирования JSON", http.StatusBadRequest)
			return
		}

		//make - это  встроенная функция Go которая используется для создания срезов байт нужного размера. В данном случае мы создаем срез байт длиной 16, который будет использоваться для хранения случайного ключа.
		var salt = make([]byte, 16)

		//rand.Read - это функция из пакета crypto/rand, которая заполняет срез байт случайными значениями. Она использует криптографически безопасный генератор случайных чисел, что делает её подходящей для генерации ключей и других чувствительных данных.
		//по сути - мы делаем случаный ключ длиной 16 байт, который будет использоваться в качестве соли для хэширования пароля
		rand.Read(salt)

		//за параметры смотри доку https://pkg.go.dev/golang.org/x/crypto/argon2
		hash := argon2.IDKey([]byte(newRegisterRequest.Password), salt, 1, 64*1024, 4, 32)

		var hashS string = base64.StdEncoding.EncodeToString(hash)

		var saltS string = base64.StdEncoding.EncodeToString(salt)

		var NewHashSalt string = hashS + "$" + saltS

		//создаем структуру для генерации ключа TOTP (Time-based One-Time Password), который будет использоваться для двухфакторной аутентификации. В структуре указываем имя нашего приложения и имя аккаунта (AccountName), которые будут отображаться в приложении для генерации одноразовых паролей (например, Google Authenticator).
		var NewGenerateOptions = totp.GenerateOpts{Issuer: "OShinobu", AccountName: newRegisterRequest.Login}

		//генерируем ключ TOTP с помощью функции totp.Generate, передавая в параметры структуру NewGenerateOptions. Функция возвращает два значения: объект ключа и ошибку генерации.
		var NewKey, KeyError = totp.Generate(NewGenerateOptions)

		//проверка на ошибки генерации ключа. Если ошибки есть, возвращаем пользователю код ошибки сервера 500 Internal Server Error и сообщение об ошибке.
		if KeyError != nil {
			http.Error(w, "Ошибка генерации ключа TOTP", http.StatusInternalServerError)
			return
		}

		//получаем ссылку на QR-код, который можно отсканировать в приложении для генерации одноразовых паролей (например, Google Authenticator)
		var NewQRCodeURL string = NewKey.URL()

		//получаем секретный ключ TOTP в виде строки, который будет храниться в базе данных и использоваться для проверки одноразовых паролей при аутентификации
		var NewSecret = NewKey.Secret()

		//создаем структуру CreateAccountParams, которая будет использоваться для передачи данных в функцию CreateAccount. В структуре указываем логин, хэшированный пароль и секретный ключ TOTP.
		var NewAccountParamsStruct = db.CreateAccountParams{
			Login:        newRegisterRequest.Login,
			PasswordHash: NewHashSalt,
			TotpSecret:   NewSecret,
		}

		//вызываем функцию создания аккаунта, получая в ответ объект с данными аккаунта и ошибку
		var NewRegAcc, NewRegAccError = queries.CreateAccount(r.Context(), NewAccountParamsStruct)

		//лоигруем о событии регистрации
		log.Printf("зарегистрирован новый аккаунт: %s (id: %s)", NewRegAcc.Login, NewRegAcc.ID)

		//проверяем есть ли ошибка при создании аккаунта. Если есть, возвращаем пользователю код ошибки сервера 500 Internal Server Error и сообщение об ошибке.
		if NewRegAccError != nil {
			http.Error(w, "Ошибка регистрации аккаунта", http.StatusInternalServerError)
			return
		}

		//создаем экземпляра структуры с ответом на регистрацию
		var NewRegisterResponse RegisterResponse

		//помещаем в ответ ссылку на QR-код, который можно отсканировать в приложении для генерации одноразовых паролей (например, Google Authenticator)
		NewRegisterResponse.TotpURL = NewQRCodeURL

		//устанавливаем тип ответа - JSON
		w.Header().Set("Content-Type", "application/json")

		//переводим наш JSON в байты и отправляем клиенту. json.NewEncoder(w).Encode(NewRegisterResponse) - это функция, которая кодирует структуру NewRegisterResponse в JSON и записывает результат в http.ResponseWriter w, который отправляет ответ клиенту.
		json.NewEncoder(w).Encode(NewRegisterResponse)

	}
}
