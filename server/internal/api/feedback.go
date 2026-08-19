package api

import (
	"encoding/json"
	"log"
	"net/http"
	"server/internal/db"
	"strings"
)

type FeedbackRequest struct {
	Message string `json:"message"`
}

func NewFeedbackHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var session, tokErr = CheckToken(w, r, queries)
		if tokErr != nil {
			log.Printf("ошибка проверки токена: %v", tokErr)
			return
		}

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

		account, err := queries.GetAccountByID(r.Context(), session.AccountID)
		if err != nil {
			http.Error(w, "Ошибка получения аккаунта", http.StatusInternalServerError)
			return
		}

		params := db.CreateFeedbackParams{
			AccountID:    session.AccountID,
			AccountLogin: account.Login,
			Message:      message,
		}
		if err := queries.CreateFeedback(r.Context(), params); err != nil {
			log.Printf("feedback: ошибка сохранения: %v", err)
			http.Error(w, "Ошибка сохранения отзыва", http.StatusInternalServerError)
			return
		}

		log.Printf("feedback: получен отзыв от %s", account.Login)
		w.WriteHeader(http.StatusOK)
	}
}
