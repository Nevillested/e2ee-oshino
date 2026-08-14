package api

import (
	"encoding/json"
	"net/http"
	"server/internal/db"
)

type AccountMeResponse struct {
	AccountID string `json:"account_id"`
	Login     string `json:"login"`
	Language  string `json:"language"`
	Email     string `json:"email,omitempty"`
	HasAvatar bool   `json:"has_avatar"`
}

func NewAccountMeHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var Session, err = CheckToken(w, r, queries)
		if err != nil {
			return
		}

		var Account, SqlErr = queries.GetAccountByID(r.Context(), Session.AccountID)
		if SqlErr != nil {
			http.Error(w, "Ошибка получения аккаунта", http.StatusInternalServerError)
			return
		}

		var Resp AccountMeResponse
		Resp.AccountID = Account.ID.String()
		Resp.Login = Account.Login
		Resp.Language = Account.Language
		if Account.Email.Valid {
			Resp.Email = Account.Email.String
		}
		Resp.HasAvatar = Account.AvatarObjectKey.Valid

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(Resp)
	}
}
