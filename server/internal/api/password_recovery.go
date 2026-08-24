package api

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"log"
	"net/http"
	"server/internal/auth"
	"server/internal/db"
	"server/internal/mail"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgtype"
	"github.com/pquerna/otp/totp"
)

const (
	recoveryTokenTTL    = 30 * time.Minute
	recoveryMaxAttempts = 5
)

// recoverRequestLimiter — сам ЗАПРОС кода (не ввод) раньше был вообще без
// лимита: только код потом ограничен по попыткам (recoveryMaxAttempts), а
// генерировать и слать новые письма можно было бесконечно — открытая
// возможность заспамить письмами чужой почтовый ящик. Ключ — логин: у
// каждого аккаунта свой бюджет запросов независимо от того, с какого IP их
// шлют.
var recoverRequestLimiter = NewRateLimiter(time.Hour, 3)

type RecoverRequestRequest struct {
	Login string `json:"login"`
}

// NewRecoverRequestHandler — POST /account/recover/request. Публичный
// эндпоинт (без токена сессии — пользователь как раз потому сюда и
// пришёл, что не может залогиниться).
//
// По явному запросу пользователя (владельца продукта) этот эндпоинт
// СОЗНАТЕЛЬНО различает "логин не найден" и "успех" отдельными кодами
// ответа — раньше оба случая маскировались под одинаковый 200 именно
// чтобы не палить существование логина, но регистрация (см. register.go,
// 409 "уже зарегистрирован") и так уже даёт способ проверить занятость
// логина, так что смысла продолжать маскировать здесь не осталось, а вот
// понятная ошибка "такого пользователя нет" пользователю сильно нужнее.
func NewRecoverRequestHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var Req RecoverRequestRequest
		if err := json.NewDecoder(r.Body).Decode(&Req); err != nil {
			http.Error(w, "Ошибка декодирования JSON", http.StatusBadRequest)
			return
		}

		login := strings.TrimSpace(Req.Login)

		// Считаем попытку запроса СРАЗУ, до любых проверок ниже — иначе
		// лимит легко обойти, узнавая заодно (по разнице в 429 vs 404),
		// какие из перебираемых логинов вообще существуют.
		if !recoverRequestLimiter.Allowed(login) {
			http.Error(w, "Слишком много запросов кода, попробуйте позже", http.StatusTooManyRequests)
			return
		}
		recoverRequestLimiter.RecordFailure(login)

		account, err := queries.GetAccountByLogin(r.Context(), login)
		if err != nil {
			http.Error(w, "Пользователь с таким логином не найден", http.StatusNotFound)
			return
		}
		if !account.Email.Valid {
			http.Error(w, "У аккаунта не указана почта для восстановления", http.StatusUnprocessableEntity)
			return
		}

		token, genErr := auth.GenerateVerificationCode()
		if genErr != nil {
			log.Printf("не удалось сгенерировать код восстановления: %v", genErr)
			http.Error(w, "Ошибка генерации кода", http.StatusInternalServerError)
			return
		}

		// Одна активная попытка восстановления за раз — новый запрос
		// аннулирует прежний код (и его счётчик попыток).
		_ = queries.DeletePasswordResetTokensForAccount(r.Context(), account.ID)

		_, createErr := queries.CreatePasswordResetToken(r.Context(), db.CreatePasswordResetTokenParams{
			AccountID: account.ID,
			TokenHash: hashVerificationCode(token),
			ExpiresAt: pgtype.Timestamptz{
				Time:             time.Now().Add(recoveryTokenTTL),
				InfinityModifier: pgtype.Finite,
				Valid:            true,
			},
		})
		if createErr != nil {
			log.Printf("не удалось сохранить код восстановления: %v", createErr)
			http.Error(w, "Ошибка сохранения кода", http.StatusInternalServerError)
			return
		}
		if sendErr := mail.SendPasswordResetCode(account.Email.String, token); sendErr != nil {
			log.Printf("не удалось отправить письмо восстановления: %v", sendErr)
			http.Error(w, "Не удалось отправить письмо", http.StatusInternalServerError)
			return
		}

		w.WriteHeader(http.StatusOK)
	}
}

type RecoverVerifyRequest struct {
	Login string `json:"login"`
	Token string `json:"token"`
}

// NewRecoverVerifyHandler — POST /account/recover/verify. Проверяет код, но
// НЕ расходует его (не удаляет, не помечает использованным) — реальная
// смена пароля идёт отдельным вызовом /account/recover/reset; этот нужен
// только чтобы клиент понял "код верный" и показал экран нового пароля, до
// того как пользователь успеет его ввести.
func NewRecoverVerifyHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var Req RecoverVerifyRequest
		if err := json.NewDecoder(r.Body).Decode(&Req); err != nil {
			http.Error(w, "Ошибка декодирования JSON", http.StatusBadRequest)
			return
		}

		ok, _, err := checkRecoveryToken(r.Context(), queries, strings.TrimSpace(Req.Login), Req.Token)
		if err != nil || !ok {
			http.Error(w, "Неверный или истёкший код", http.StatusUnauthorized)
			return
		}

		w.WriteHeader(http.StatusOK)
	}
}

type RecoverResetRequest struct {
	Login       string `json:"login"`
	Token       string `json:"token"`
	NewPassword string `json:"new_password"`
}

// NewRecoverResetHandler — POST /account/recover/reset. Финальный шаг:
// повторно проверяет код (клиент мог придержать его какое-то время между
// verify и этим вызовом — перепроверка не даёт коду "протухнуть" незаметно
// для проверки, но остаться валидным для смены пароля) и, если всё в
// порядке, меняет пароль и сразу инвалидирует код — использованный код
// повторно не сработает.
func NewRecoverResetHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var Req RecoverResetRequest
		if err := json.NewDecoder(r.Body).Decode(&Req); err != nil {
			http.Error(w, "Ошибка декодирования JSON", http.StatusBadRequest)
			return
		}

		login := strings.TrimSpace(Req.Login)
		ok, account, err := checkRecoveryToken(r.Context(), queries, login, Req.Token)
		if err != nil || !ok {
			http.Error(w, "Неверный или истёкший код", http.StatusUnauthorized)
			return
		}

		if PolicyErr := auth.ValidatePassword(Req.NewPassword); PolicyErr != nil {
			http.Error(w, PolicyErr.Error(), http.StatusBadRequest)
			return
		}

		hash, hashErr := auth.HashPassword(Req.NewPassword)
		if hashErr != nil {
			http.Error(w, "Ошибка хеширования пароля", http.StatusInternalServerError)
			return
		}

		if sqlErr := queries.UpdateAccountPasswordHash(r.Context(), db.UpdateAccountPasswordHashParams{
			ID:           account.ID,
			PasswordHash: hash,
		}); sqlErr != nil {
			http.Error(w, "Ошибка сохранения пароля", http.StatusInternalServerError)
			return
		}

		_ = queries.DeletePasswordResetTokensForAccount(r.Context(), account.ID)

		log.Printf("пароль восстановлен для аккаунта: %s (id: %s)", account.Login, account.ID)
		w.WriteHeader(http.StatusOK)
	}
}

type RecoverResetTotpResponse struct {
	TotpURL string `json:"totp_url"`
}

// NewRecoverResetTotpHandler — POST /account/recover/reset-totp. Второй
// "финальный шаг" восстановления, по тому же коду с почты, что и
// /account/recover/reset у пароля (см. checkRecoveryToken — она общая для
// обеих веток, ничего пароль/TOTP-специфичного не проверяет). В отличие от
// смены пароля тут нечего принимать от пользователя — новый TOTP-секрет
// всегда генерируется заново, тем же способом, что и при регистрации (см.
// register.go), и возвращается клиенту той же формой ответа (totp_url) —
// дальше на клиенте один и тот же экран подтверждения (сканирование QR +
// текущий код), что при регистрации.
func NewRecoverResetTotpHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var Req RecoverVerifyRequest
		if err := json.NewDecoder(r.Body).Decode(&Req); err != nil {
			http.Error(w, "Ошибка декодирования JSON", http.StatusBadRequest)
			return
		}

		login := strings.TrimSpace(Req.Login)
		ok, account, err := checkRecoveryToken(r.Context(), queries, login, Req.Token)
		if err != nil || !ok {
			http.Error(w, "Неверный или истёкший код", http.StatusUnauthorized)
			return
		}

		key, genErr := totp.Generate(totp.GenerateOpts{Issuer: "OShinobu", AccountName: account.Login})
		if genErr != nil {
			log.Printf("не удалось сгенерировать новый TOTP-секрет при восстановлении: %v", genErr)
			http.Error(w, "Ошибка генерации ключа TOTP", http.StatusInternalServerError)
			return
		}

		if sqlErr := queries.UpdateAccountTotpSecret(r.Context(), db.UpdateAccountTotpSecretParams{
			ID:         account.ID,
			TotpSecret: key.Secret(),
		}); sqlErr != nil {
			log.Printf("не удалось сохранить новый TOTP-секрет: %v", sqlErr)
			http.Error(w, "Ошибка сохранения ключа TOTP", http.StatusInternalServerError)
			return
		}

		// Тот же одноразовый расход кода, что и у смены пароля — повторно
		// этот код (и на пароль, и на TOTP) больше не сработает.
		_ = queries.DeletePasswordResetTokensForAccount(r.Context(), account.ID)

		log.Printf("TOTP-секрет восстановлен для аккаунта: %s (id: %s)", account.Login, account.ID)

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(RecoverResetTotpResponse{TotpURL: key.URL()})
	}
}

// checkRecoveryToken — общая проверка для verify и reset: находит аккаунт,
// его последний код восстановления, сверяет хеш константным временем,
// проверяет срок годности и лимит попыток. Неудачное сравнение хеша
// увеличивает счётчик попыток — так код нельзя перебирать бесконечно
// (recoveryMaxAttempts на весь код, не в час и т.п.).
func checkRecoveryToken(ctx context.Context, queries *db.Queries, login, token string) (bool, db.Account, error) {
	account, err := queries.GetAccountByLogin(ctx, login)
	if err != nil {
		return false, db.Account{}, err
	}

	stored, err := queries.GetLatestPasswordResetToken(ctx, account.ID)
	if err != nil {
		return false, account, err
	}

	if stored.Attempts >= recoveryMaxAttempts {
		return false, account, nil
	}
	if time.Now().After(stored.ExpiresAt.Time) {
		return false, account, nil
	}

	providedHash := hashVerificationCode(strings.ToUpper(strings.TrimSpace(token)))
	match := subtle.ConstantTimeCompare([]byte(providedHash), []byte(stored.TokenHash)) == 1
	if !match {
		_ = queries.IncrementPasswordResetAttempts(ctx, stored.ID)
		return false, account, nil
	}

	return true, account, nil
}

func hashVerificationCode(token string) string {
	sum := sha256.Sum256([]byte(token))
	return base64.StdEncoding.EncodeToString(sum[:])
}
