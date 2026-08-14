package api

import (
	"encoding/json"
	"net/http"
	"server/internal/auth"
	"server/internal/db"
)

type ChangePasswordRequest struct {
	NewPassword string `json:"new_password"`
}

// NewChangePasswordHandler — PUT /account/password. Смена пароля ВНУТРИ
// уже открытого аккаунта (настройки) — в отличие от восстановления, тут
// не нужен код с почты: пользователь уже аутентифицирован токеном сессии
// (см. CheckToken), этого достаточно. Старый пароль тоже не спрашиваем —
// раз токен валиден, личность уже подтверждена самим фактом входа.
func NewChangePasswordHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		Session, err := CheckToken(w, r, queries)
		if err != nil {
			return
		}

		var Req ChangePasswordRequest
		if DecodeErr := json.NewDecoder(r.Body).Decode(&Req); DecodeErr != nil {
			http.Error(w, "Ошибка декодирования JSON", http.StatusBadRequest)
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
			ID:           Session.AccountID,
			PasswordHash: hash,
		}); sqlErr != nil {
			http.Error(w, "Ошибка сохранения пароля", http.StatusInternalServerError)
			return
		}

		w.WriteHeader(http.StatusOK)
	}
}
