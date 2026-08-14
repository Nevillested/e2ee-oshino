package api

import (
	"encoding/json"
	"net/http"
	"regexp"
	"server/internal/db"
	"strings"

	"github.com/jackc/pgx/v5/pgtype"
)

type UpdateLanguageRequest struct {
	Language string `json:"language"`
}

// Язык хранится на сервере (не только локально в клиенте) — задел под
// вход с нескольких устройств в будущем: пока это просто значение,
// применяемое сразу при логине (см. LoginResponse.Language).
func NewUpdateLanguageHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var Session, err = CheckToken(w, r, queries)
		if err != nil {
			return
		}

		var Req UpdateLanguageRequest
		if DecodeErr := json.NewDecoder(r.Body).Decode(&Req); DecodeErr != nil {
			http.Error(w, "Ошибка декодирования JSON", http.StatusBadRequest)
			return
		}

		var Lang = strings.TrimSpace(Req.Language)
		if Lang != "ru" && Lang != "en" {
			http.Error(w, "Неподдерживаемый язык", http.StatusBadRequest)
			return
		}

		var SqlErr = queries.UpdateAccountLanguage(r.Context(), db.UpdateAccountLanguageParams{
			ID:       Session.AccountID,
			Language: Lang,
		})
		if SqlErr != nil {
			http.Error(w, "Ошибка сохранения языка", http.StatusInternalServerError)
			return
		}

		w.WriteHeader(http.StatusOK)
	}
}

type UpdateEmailRequest struct {
	Email string `json:"email"`
}

// Простая проверка формата — не полноценная валидация RFC 5322 (она и не
// нужна тут), просто отсекает явный мусор до того, как значение уйдёт в
// базу. Реальная отправка кода восстановления на эту почту — отдельная,
// пока не реализованная часть (нужен SMTP/почтовый сервис), сейчас это
// только хранение адреса на будущее.
var emailFormatRe = regexp.MustCompile(`^[^\s@]+@[^\s@]+\.[^\s@]+$`)

func NewUpdateEmailHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var Session, err = CheckToken(w, r, queries)
		if err != nil {
			return
		}

		var Req UpdateEmailRequest
		if DecodeErr := json.NewDecoder(r.Body).Decode(&Req); DecodeErr != nil {
			http.Error(w, "Ошибка декодирования JSON", http.StatusBadRequest)
			return
		}

		var Email = strings.TrimSpace(Req.Email)
		var EmailValue pgtype.Text
		if Email == "" {
			// Пустая строка — снять почту с аккаунта (поле опциональное).
			EmailValue = pgtype.Text{Valid: false}
		} else {
			if !emailFormatRe.MatchString(Email) {
				http.Error(w, "Неверный формат почты", http.StatusBadRequest)
				return
			}
			EmailValue = pgtype.Text{String: Email, Valid: true}
		}

		var SqlErr = queries.UpdateAccountEmail(r.Context(), db.UpdateAccountEmailParams{
			ID:    Session.AccountID,
			Email: EmailValue,
		})
		if SqlErr != nil {
			http.Error(w, "Ошибка сохранения почты", http.StatusInternalServerError)
			return
		}

		w.WriteHeader(http.StatusOK)
	}
}
