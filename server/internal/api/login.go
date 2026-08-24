package api

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/json"
	"net/http"
	"server/internal/db"
	"strings"

	"encoding/base64"

	"crypto/sha256"
	"time"

	"github.com/jackc/pgx/v5/pgtype"
	"github.com/pquerna/otp/totp"
	"golang.org/x/crypto/argon2"
)

type LoginRequest struct {
	Login    string `json:"login"`
	Password string `json:"password"`
	TotpCode string `json:"totp_code"`
}

type LoginResponse struct {
	Token    string `json:"token"`
	Language string `json:"language"`
}

// perAccountLoginLimiter — отдельный, более широкий лимит ПО ОДНОМУ ЛОГИНУ
// (без привязки к IP): защищает конкретный аккаунт от распределённого
// перебора с разных адресов, который ip+login лимитер ниже не поймает (у
// каждой отдельной пары ip+login свой маленький бюджет).
var perAccountLoginLimiter = NewRateLimiter(15*time.Minute, 15)

func NewLoginHandler(queries *db.Queries, limiter *RateLimiter) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {

		//объявляем переменную, где будут храниться данные логина и кода TOTP, которые пришли от клиента в JSON-формате
		var NewDataFromClient LoginRequest

		//объявляем переменную, которая будет декодировать из байтов в структуру RegisterRequest
		var NewDecoder = json.NewDecoder(r.Body)

		//переводим из байтового вида и записываем в созданный экземпляр
		var DecodeError = NewDecoder.Decode(&NewDataFromClient)

		//если произошла ошибка при декодировании JSON, то выводим сообщение об ошибке и возвращаем клиенту статус 500
		if DecodeError != nil {
			http.Error(w, "Ошибка декодирования JSON", http.StatusBadRequest)
			return
		}

		//переводим из JSON в строки - логин, код и пароль
		var LoginFromClient string = NewDataFromClient.Login
		var TOTPCodeFromClient string = NewDataFromClient.TotpCode
		var PWDFromClient string = NewDataFromClient.Password

		var ip = clientIP(r)
		// Ключ "ip|login" — а не просто ip — чтобы неудачные попытки против
		// ОДНОГО аккаунта с общего IP (офис/CGNAT/VPN) не блокировали вход
		// остальным, кто сидит за тем же IP, но логинится в СВОИ аккаунты.
		var ipLoginKey = ip + "|" + LoginFromClient
		if !limiter.Allowed(ipLoginKey) || !perAccountLoginLimiter.Allowed(LoginFromClient) {
			http.Error(w, "Слишком много неудачных попыток входа, попробуйте позже", http.StatusTooManyRequests)
			return
		}

		//делаем запрос к бд, передавая в качестве параметра логин, который пришел от клиента. В ответ получаем структуру Account, которая содержит все данные аккаунта, включая секретный ключ TOTP, который сохранили на этапе регистрации
		var account, SqlError = queries.GetAccountByLogin(r.Context(), LoginFromClient)

		//проверяем ошибки, при запросе к бд — намеренно НЕ отличаем от "неверный
		//пароль/код" ни статусом, ни текстом ответа (см. ветку else ниже) —
		//иначе сам факт разного ответа выдавал бы, существует логин или нет.
		if SqlError != nil {
			limiter.RecordFailure(ipLoginKey)
			perAccountLoginLimiter.RecordFailure(LoginFromClient)
			http.Error(w, "Неверные данные входа", http.StatusUnauthorized)
			return
		}

		//переменная для хранения секрета аутентификатор
		var UserSecret string = account.TotpSecret

		//переменная для хранения полученного кода от пользователя
		var UserCode string = TOTPCodeFromClient

		//проверяем код, запоминаем результат - первое значение, которое потребуется для итоговой проверки
		var CheckCodeResult bool = totp.Validate(UserCode, UserSecret)

		//Сравниваем пароли. Чтобы их сравнить, нужно каждый из них перевести в массив байтов.
		//Но преждем всего - надо получить хэш введенного пользователем пароля и хэш пароля, который в бд
		//В бд лежит не хэш, а конкатенация соли и хэша.

		//это - сконкатенированная соль и хэш пароля
		var ConcatSaltHash string = account.PasswordHash

		//разделим на соль и хэш пароля
		var parts = strings.Split(ConcatSaltHash, "$")

		//получаем хэш пароля при регистрации
		var HashS string = parts[0]

		//получаем соль при регистрации
		var SaltS string = parts[1]

		//декодируем обе части обратно в байты
		var storedHash, _ = base64.StdEncoding.DecodeString(HashS)
		var salt, _ = base64.StdEncoding.DecodeString(SaltS)

		//заново вычислить Хэш пароля с той же солью
		var NewHash = argon2.IDKey([]byte(PWDFromClient), salt, 1, 64*1024, 4, 32)

		//Сравниваем пароли. 1 - пароль подходит, 0 пароль не подходит - второе значение, которое потребуется для итоговой проверки
		var PWDCheck = subtle.ConstantTimeCompare(NewHash, storedHash)

		//отправляем результат
		if CheckCodeResult && PWDCheck == 1 {
			limiter.RecordSuccess(ipLoginKey)
			perAccountLoginLimiter.RecordSuccess(LoginFromClient)

			//генерируем срез в 32 байта
			var tokenBytes = make([]byte, 32)

			//создаем рандомный токен в байтах и помещаем в срез
			rand.Read(tokenBytes)

			//переводим токен в строку
			var token string = base64.StdEncoding.EncodeToString(tokenBytes)

			//формируем хэш токен по sha256
			var hashArray [32]byte = sha256.Sum256([]byte(token))
			var tokenHash string = base64.StdEncoding.EncodeToString(hashArray[:])

			//проставляем дату срока годности токена
			var expiresAt = time.Now().Add(30 * 24 * time.Hour)

			//создаем экземпляр параметров, который передадим потом на исполнение для создания сесии
			var NewSessionParams db.CreateSessionParams

			/*
				type Timestamptz struct {
					Time             time.Time
					InfinityModifier InfinityModifier
					Valid            bool
				}
			*/

			//помещаем значения в созданный экземпляр параметров
			NewSessionParams.AccountID = account.ID
			NewSessionParams.TokenHash = tokenHash
			NewSessionParams.ExpiresAt = pgtype.Timestamptz{Time: expiresAt, InfinityModifier: pgtype.Finite, Valid: true}

			//вызываем функцию создания аккаунта, получая в ответ объект с данными аккаунта и ошибку
			var _, SessionError = queries.CreateSession(r.Context(), NewSessionParams)

			//проверяем есть ли ошибка при запоминании сессии
			if SessionError != nil {
				http.Error(w, "Ошибка Создания сессии", http.StatusInternalServerError)
				return
			}

			//создаем экземпляра структуры с ответом на логин
			var NewLoginResponse LoginResponse

			//помещаем в ответ токен сессии
			NewLoginResponse.Token = token
			//и текущий язык интерфейса, сохранённый на сервере — клиент
			//применяет его сразу при входе, не дожидаясь отдельного запроса
			NewLoginResponse.Language = account.Language

			//устанавливаем тип ответа - JSON
			w.Header().Set("Content-Type", "application/json")

			//переводим наш JSON в байты и отправляем клиенту. json.NewEncoder(w).Encode(NewLoginResponse) - это функция, которая кодирует структуру NewLoginResponse в JSON и записывает результат в http.ResponseWriter w, который отправляет ответ клиенту.
			json.NewEncoder(w).Encode(NewLoginResponse)

		} else {
			limiter.RecordFailure(ipLoginKey)
			perAccountLoginLimiter.RecordFailure(LoginFromClient)
			http.Error(w, "Неверные данные входа", http.StatusUnauthorized)
		}

		//проверка
		//curl -i -X POST http://127.0.0.1:8080/login -H "Content-Type: application/json" -d '{"login":"alice","password":"supersecret123","totp_code":"ТЕКУЩИЙ_КОД_ИЗ_АУТЕНТИФИКАТОРА"}'

	}
}
