package api

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"server/internal/auth"
	"server/internal/db"
	"server/internal/mail"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
)

const (
	emailVerificationTTL         = 30 * time.Minute
	emailVerificationMaxAttempts = 5
)

type RequestEmailVerificationRequest struct {
	Email string `json:"email"`
}

// NewRequestEmailVerificationHandler — POST /account/email/request. Первый
// шаг привязки почты в настройках: проверяет формат и что почта ещё не
// занята ДРУГИМ аккаунтом, генерирует код и шлёт его на указанный адрес.
// accounts.email при этом ещё не меняется — только после успешного
// /account/email/confirm. Без этого шага пользователь мог бы вписать чужую
// почту и получать по ней письма для восстановления пароля.
func NewRequestEmailVerificationHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		Session, err := CheckToken(w, r, queries)
		if err != nil {
			return
		}

		var Req RequestEmailVerificationRequest
		if DecodeErr := json.NewDecoder(r.Body).Decode(&Req); DecodeErr != nil {
			http.Error(w, "Ошибка декодирования JSON", http.StatusBadRequest)
			return
		}

		email := strings.TrimSpace(Req.Email)
		if !emailFormatRe.MatchString(email) {
			http.Error(w, "Неверный формат почты", http.StatusBadRequest)
			return
		}

		// Почта должна однозначно указывать на один аккаунт — если её уже
		// подтвердил кто-то другой, отправлять код нет смысла. UNIQUE на
		// accounts.email всё равно поймает это окончательно на confirm (см.
		// ниже), но так пользователь узнаёт об этом сразу, а не после ввода
		// кода из письма.
		existing, lookupErr := queries.GetAccountByEmail(r.Context(), pgtype.Text{String: email, Valid: true})
		if lookupErr == nil && existing.ID != Session.AccountID {
			http.Error(w, "Эта почта уже привязана к другому аккаунту", http.StatusConflict)
			return
		}

		code, genErr := auth.GenerateVerificationCode()
		if genErr != nil {
			log.Printf("не удалось сгенерировать код подтверждения почты: %v", genErr)
			http.Error(w, "Ошибка генерации кода", http.StatusInternalServerError)
			return
		}

		// Одна активная попытка за раз — новый запрос аннулирует прежний код.
		_ = queries.DeleteEmailVerificationTokensForAccount(r.Context(), Session.AccountID)

		_, createErr := queries.CreateEmailVerificationToken(r.Context(), db.CreateEmailVerificationTokenParams{
			AccountID: Session.AccountID,
			Email:     email,
			TokenHash: hashVerificationCode(code),
			ExpiresAt: pgtype.Timestamptz{
				Time:             time.Now().Add(emailVerificationTTL),
				InfinityModifier: pgtype.Finite,
				Valid:            true,
			},
		})
		if createErr != nil {
			log.Printf("не удалось сохранить код подтверждения почты: %v", createErr)
			http.Error(w, "Ошибка сохранения кода", http.StatusInternalServerError)
			return
		}

		if sendErr := mail.SendEmailVerificationCode(email, code); sendErr != nil {
			log.Printf("не удалось отправить письмо подтверждения почты: %v", sendErr)
			http.Error(w, "Не удалось отправить письмо", http.StatusInternalServerError)
			return
		}

		w.WriteHeader(http.StatusOK)
	}
}

type ConfirmEmailVerificationRequest struct {
	Code string `json:"code"`
}

// NewConfirmEmailVerificationHandler — POST /account/email/confirm. Второй
// шаг: проверяет код (та же схема — хеш константным временем, лимит попыток,
// срок годности, см. checkRecoveryToken в password_recovery.go) и, если всё
// верно, только теперь реально записывает почту в accounts.email.
func NewConfirmEmailVerificationHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		Session, err := CheckToken(w, r, queries)
		if err != nil {
			return
		}

		var Req ConfirmEmailVerificationRequest
		if DecodeErr := json.NewDecoder(r.Body).Decode(&Req); DecodeErr != nil {
			http.Error(w, "Ошибка декодирования JSON", http.StatusBadRequest)
			return
		}

		stored, err := queries.GetLatestEmailVerificationToken(r.Context(), Session.AccountID)
		if err != nil {
			http.Error(w, "Код не запрашивался", http.StatusUnauthorized)
			return
		}

		if stored.Attempts >= emailVerificationMaxAttempts {
			http.Error(w, "Неверный или истёкший код", http.StatusUnauthorized)
			return
		}
		if time.Now().After(stored.ExpiresAt.Time) {
			http.Error(w, "Неверный или истёкший код", http.StatusUnauthorized)
			return
		}

		providedHash := hashVerificationCode(strings.ToUpper(strings.TrimSpace(Req.Code)))
		match := subtle.ConstantTimeCompare([]byte(providedHash), []byte(stored.TokenHash)) == 1
		if !match {
			_ = queries.IncrementEmailVerificationAttempts(r.Context(), stored.ID)
			http.Error(w, "Неверный или истёкший код", http.StatusUnauthorized)
			return
		}

		sqlErr := queries.UpdateAccountEmail(r.Context(), db.UpdateAccountEmailParams{
			ID:    Session.AccountID,
			Email: pgtype.Text{String: stored.Email, Valid: true},
		})
		if sqlErr != nil {
			// На случай гонки: кто-то другой успел подтвердить ЭТУ ЖЕ почту на
			// свой аккаунт между /request и этим вызовом — UNIQUE-ограничение
			// на accounts.email ловит это здесь окончательно.
			var pgErr *pgconn.PgError
			if errors.As(sqlErr, &pgErr) && pgErr.Code == "23505" {
				http.Error(w, "Эта почта уже привязана к другому аккаунту", http.StatusConflict)
				return
			}
			http.Error(w, "Ошибка сохранения почты", http.StatusInternalServerError)
			return
		}

		_ = queries.DeleteEmailVerificationTokensForAccount(r.Context(), Session.AccountID)

		w.WriteHeader(http.StatusOK)
	}
}
