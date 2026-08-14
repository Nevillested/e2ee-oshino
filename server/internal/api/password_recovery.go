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
)

const (
	recoveryTokenTTL    = 30 * time.Minute
	recoveryMaxAttempts = 5
)

type RecoverRequestRequest struct {
	Login string `json:"login"`
}

// NewRecoverRequestHandler — POST /account/recover/request. Публичный
// эндпоинт (без токена сессии — пользователь как раз потому сюда и
// пришёл, что не может залогиниться). Всегда отвечает 200 с одинаковым
// телом, независимо от того, нашёлся аккаунт и указана ли у него почта —
// иначе по разнице ответов можно было бы перебором узнавать, какие логины
// вообще существуют в системе.
func NewRecoverRequestHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var Req RecoverRequestRequest
		if err := json.NewDecoder(r.Body).Decode(&Req); err != nil {
			http.Error(w, "Ошибка декодирования JSON", http.StatusBadRequest)
			return
		}

		login := strings.TrimSpace(Req.Login)
		account, err := queries.GetAccountByLogin(r.Context(), login)
		if err == nil && account.Email.Valid {
			token, genErr := auth.GenerateRecoveryToken()
			if genErr != nil {
				log.Printf("не удалось сгенерировать код восстановления: %v", genErr)
			} else {
				// Одна активная попытка восстановления за раз — новый запрос
				// аннулирует прежний код (и его счётчик попыток).
				_ = queries.DeletePasswordResetTokensForAccount(r.Context(), account.ID)

				_, createErr := queries.CreatePasswordResetToken(r.Context(), db.CreatePasswordResetTokenParams{
					AccountID: account.ID,
					TokenHash: hashRecoveryToken(token),
					ExpiresAt: pgtype.Timestamptz{
						Time:             time.Now().Add(recoveryTokenTTL),
						InfinityModifier: pgtype.Finite,
						Valid:            true,
					},
				})
				if createErr != nil {
					log.Printf("не удалось сохранить код восстановления: %v", createErr)
				} else if sendErr := mail.SendPasswordResetCode(account.Email.String, token); sendErr != nil {
					log.Printf("не удалось отправить письмо восстановления: %v", sendErr)
				}
			}
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

		if len(Req.NewPassword) < 6 {
			http.Error(w, "Пароль слишком короткий", http.StatusBadRequest)
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

	providedHash := hashRecoveryToken(strings.ToUpper(strings.TrimSpace(token)))
	match := subtle.ConstantTimeCompare([]byte(providedHash), []byte(stored.TokenHash)) == 1
	if !match {
		_ = queries.IncrementPasswordResetAttempts(ctx, stored.ID)
		return false, account, nil
	}

	return true, account, nil
}

func hashRecoveryToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return base64.StdEncoding.EncodeToString(sum[:])
}
