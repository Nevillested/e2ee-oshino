package api

import (
	"encoding/json"
	"log"
	"net/http"
	"server/internal/db"
	"strings"
)

// Раньше сюда попадал только текст, набранный пользователем вручную в
// "О приложении" (kind по умолчанию "user" — см. миграцию 021). Теперь
// основной источник — CrashReporter на клиенте: тихая автоматическая
// отправка diagnostic-лога при настоящей ошибке, kind="auto_crash" (см.
// client/lib/services/crash_reporter.dart). Ручная форма отзыва убрана из
// приложения полностью, но сам эндпоинт/таблица переиспользованы как есть —
// разбираться со старыми и новыми записями удобнее в одном месте (см.
// server/cmd/admin/reports_feedback.go).
const maxFeedbackBodyBytes = 2 * 1024 * 1024

type FeedbackRequest struct {
	Message string `json:"message"`
	Kind    string `json:"kind"`
}

func NewFeedbackHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var session, tokErr = CheckToken(w, r, queries)
		if tokErr != nil {
			log.Printf("ошибка проверки токена: %v", tokErr)
			return
		}

		r.Body = http.MaxBytesReader(w, r.Body, maxFeedbackBodyBytes)
		var req FeedbackRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "Ошибка декодирования JSON", http.StatusBadRequest)
			return
		}

		message := strings.TrimSpace(req.Message)
		if message == "" {
			http.Error(w, "Пустое сообщение", http.StatusBadRequest)
			return
		}

		kind := strings.TrimSpace(req.Kind)
		if kind == "" {
			kind = "user"
		}

		account, err := queries.GetAccountByID(r.Context(), session.AccountID)
		if err != nil {
			http.Error(w, "Ошибка получения аккаунта", http.StatusInternalServerError)
			return
		}

		params := db.CreateFeedbackParams{
			AccountID:    session.AccountID,
			AccountLogin: account.Login,
			Message:      message,
			Kind:         kind,
		}
		if err := queries.CreateFeedback(r.Context(), params); err != nil {
			log.Printf("feedback: ошибка сохранения: %v", err)
			http.Error(w, "Ошибка сохранения отзыва", http.StatusInternalServerError)
			return
		}

		log.Printf("feedback: получено (kind=%s) от %s", kind, account.Login)
		w.WriteHeader(http.StatusOK)
	}
}
