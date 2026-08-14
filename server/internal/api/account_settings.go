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
// базу. Используется и здесь, и в account_email_verification.go.
var emailFormatRe = regexp.MustCompile(`^[^\s@]+@[^\s@]+\.[^\s@]+$`)

// NewUpdateEmailHandler — PUT /account/email. Теперь только для СНЯТИЯ
// почты (пустая строка) — установка новой почты требует подтверждения
// владения (см. account_email_verification.go, POST /account/email/request
// и /confirm), иначе запись в accounts.email могла бы указывать на чужой
// адрес, которым пользователь не владеет. Непустое значение сюда сознательно
// отклоняется — на случай, если клиент по ошибке (или в обход UI) стукнется
// напрямую.
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
		if Email != "" {
			http.Error(w, "Для установки почты используйте подтверждение по коду", http.StatusBadRequest)
			return
		}

		var SqlErr = queries.UpdateAccountEmail(r.Context(), db.UpdateAccountEmailParams{
			ID:    Session.AccountID,
			Email: pgtype.Text{Valid: false},
		})
		if SqlErr != nil {
			http.Error(w, "Ошибка сохранения почты", http.StatusInternalServerError)
			return
		}

		w.WriteHeader(http.StatusOK)
	}
}
