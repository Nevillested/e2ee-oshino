package api

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"server/internal/auth"
	"server/internal/db"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/pquerna/otp/totp"
)

type RegisterRequest struct {
	Login      string `json:"login"`
	Password   string `json:"password"`
	InviteCode string `json:"invite_code"`
}

type RegisterResponse struct {
	TotpURL string `json:"totp_url"`
}

func NewRegisterHandler(queries *db.Queries, pool *pgxpool.Pool) func(http.ResponseWriter, *http.Request) {
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

		//только латиница и цифры, 3-32 символа — среди прочего закрывает
		//обход reservedLogins через кириллический омоглиф (см. auth.ValidateLogin).
		if LoginPolicyErr := auth.ValidateLogin(newRegisterRequest.Login); LoginPolicyErr != nil {
			http.Error(w, LoginPolicyErr.Error(), http.StatusBadRequest)
			return
		}

		//логины вида "admin"/"support"/"oshino" зарезервированы — иначе ими
		//мог бы представиться кто угодно, а собеседник в 1-в-1 переписке
		//видит только сам логин, без какой-либо отдельной "галочки" сервиса.
		if auth.IsReservedLogin(newRegisterRequest.Login) {
			http.Error(w, "Этот логин зарезервирован", http.StatusForbidden)
			return
		}

		//единые требования к паролю — та же проверка, что и при восстановлении
		//пароля и смене пароля в настройках (см. auth.ValidatePassword).
		if PolicyErr := auth.ValidatePassword(newRegisterRequest.Password); PolicyErr != nil {
			http.Error(w, PolicyErr.Error(), http.StatusBadRequest)
			return
		}

		//мессенджер закрыт для случайной публичной регистрации — код
		//обязателен, сама его валидность (существует/ещё не использован)
		//проверяется позже, атомарно вместе с созданием аккаунта (см. ниже).
		var InviteCode string = strings.TrimSpace(newRegisterRequest.InviteCode)
		if InviteCode == "" {
			http.Error(w, "Нужен пригласительный код", http.StatusBadRequest)
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

		//аккаунт и гашение инвайт-кода — одна транзакция: если код окажется
		//невалидным/уже использованным, откатывается и уже созданный аккаунт,
		//а не остаётся в базе "наполовину зарегистрированным" без кода.
		Tx, TxErr := pool.Begin(r.Context())
		if TxErr != nil {
			http.Error(w, "Ошибка регистрации аккаунта", http.StatusInternalServerError)
			return
		}
		defer Tx.Rollback(r.Context())
		TxQueries := queries.WithTx(Tx)

		//вызываем функцию создания аккаунта, получая в ответ объект с данными аккаунта и ошибку
		var NewRegAcc, NewRegAccError = TxQueries.CreateAccount(r.Context(), NewAccountParamsStruct)

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

		//гасим инвайт-код на только что созданный аккаунт — WHERE used_at IS
		//NULL в самом запросе (см. invite_codes.sql) делает это атомарным:
		//при гонке двух регистраций с одним кодом ровно одна получит строку
		//обратно, вторая — pgx.ErrNoRows.
		var _, ConsumeErr = TxQueries.ConsumeInviteCode(r.Context(), db.ConsumeInviteCodeParams{
			Code:            InviteCode,
			UsedByAccountID: NewRegAcc.ID,
		})
		if ConsumeErr != nil {
			if errors.Is(ConsumeErr, pgx.ErrNoRows) {
				http.Error(w, "Неверный или уже использованный пригласительный код", http.StatusUnprocessableEntity)
				return
			}
			http.Error(w, "Ошибка регистрации аккаунта", http.StatusInternalServerError)
			return
		}

		if CommitErr := Tx.Commit(r.Context()); CommitErr != nil {
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
