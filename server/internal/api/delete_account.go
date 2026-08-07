package api

import (
	"net/http"
	"server/internal/db"
)

// удаление аккаунта
func NewDeleteAccountHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var Session, err = CheckToken(w, r, queries)
		if err != nil {
			return
		}

		var DelErr = queries.DeleteAccount(r.Context(), Session.AccountID)
		if DelErr != nil {
			http.Error(w, "Не удалось удалить аккаунт", http.StatusInternalServerError)
			return
		}

		w.WriteHeader(http.StatusOK)
	}
}
