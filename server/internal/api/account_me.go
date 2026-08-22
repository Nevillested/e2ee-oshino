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
	// Собственный статус/дата рождения/настройки приватности — без
	// ограничений (это же сам владелец аккаунта), нужны клиенту сразу
	// после логина, чтобы заполнить MyProfileStore без отдельного похода
	// в сеть (см. account_profile.go для эндпоинтов их изменения).
	Status                string `json:"status,omitempty"`
	Birthday              string `json:"birthday,omitempty"`
	FindByLoginVisibility int16  `json:"find_by_login_visibility"`
	AvatarVisibility      int16  `json:"avatar_visibility"`
	BirthdayVisibility    int16  `json:"birthday_visibility"`
	StatusVisibility      int16  `json:"status_visibility"`
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
		if Account.StatusText.Valid {
			Resp.Status = Account.StatusText.String
		}
		if Account.Birthday.Valid {
			Resp.Birthday = Account.Birthday.Time.Format("2006-01-02")
		}
		Resp.FindByLoginVisibility = Account.FindByLoginVisibility
		Resp.AvatarVisibility = Account.AvatarVisibility
		Resp.BirthdayVisibility = Account.BirthdayVisibility
		Resp.StatusVisibility = Account.StatusVisibility

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(Resp)
	}
}
