package api

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"server/internal/auth"
	"server/internal/db"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/pquerna/otp/totp"
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

		//хеширование пароля (argon2id + соль, формат "hash$salt") — общая
		//функция в internal/auth, её же использует ручной сброс пароля в
		//cmd/admin, чтобы параметры хеширования не могли разойтись.
		var NewHashSalt, HashError = auth.HashPassword(newRegisterRequest.Password)

		if HashError != nil {
			http.Error(w, "Ошибка хеширования пароля", http.StatusInternalServerError)
			return
		}

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

		//проверяем есть ли ошибка при создании аккаунта. Раньше лог "зарегистрирован
		//новый аккаунт" писался ЗДЕСЬ безусловно, даже если аккаунт так и не
		//создался — из-за этого в логе появлялась пустая строка (NewRegAcc в
		//этом случае просто нулевая структура). Теперь логируем только после
		//успеха, ниже.
		if NewRegAccError != nil {
			//login UNIQUE в схеме — самая частая причина ошибки здесь: логин
			//уже занят. Отличаем этот случай от прочих ошибок БД отдельным
			//статусом (409), чтобы клиент показал понятное "логин уже занят",
			//а не общее "ошибка регистрации".
			var pgErr *pgconn.PgError
			if errors.As(NewRegAccError, &pgErr) && pgErr.Code == "23505" {
				http.Error(w, "Пользователь с таким логином уже зарегистрирован", http.StatusConflict)
				return
			}
			http.Error(w, "Ошибка регистрации аккаунта", http.StatusInternalServerError)
			return
		}

		//лоигруем о событии регистрации — только если аккаунт реально создан
		log.Printf("зарегистрирован новый аккаунт: %s (id: %s)", NewRegAcc.Login, NewRegAcc.ID)

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
