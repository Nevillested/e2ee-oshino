package api

import (
	"errors"
	"log"
	"net/http"
	"server/internal/db"

	"encoding/json"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

type DeviceOwnerResponse struct {
	AccountID string `json:"account_id"`
	Login     string `json:"login"`
	// Готовое к показу имя — display_name, если задан, иначе login (см.
	// тот же coalesce в account_profile.go/ProfileResponse.DisplayName).
	DisplayName string `json:"display_name"`
}

func NewGetDeviceOwnerHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {

		var _, ErrTokCheck = CheckToken(w, r, queries)
		if ErrTokCheck != nil {
			log.Printf("ошибка проверки токена: %v", ErrTokCheck)
			return
		}

		var deviceIDStr string = r.PathValue("device_id")

		var DeviceID pgtype.UUID
		ScanUuidErr := DeviceID.Scan(deviceIDStr)
		if ScanUuidErr != nil {
			http.Error(w, "Ошибка конвертации Device ID", http.StatusBadRequest)
			return
		}

		var row, SqlErr = queries.GetLoginByDeviceID(r.Context(), DeviceID)
		if SqlErr != nil {
			if errors.Is(SqlErr, pgx.ErrNoRows) {
				http.Error(w, "Устройство не найдено", http.StatusNotFound)
			} else {
				http.Error(w, "Ошибка поиска владельца устройства", http.StatusInternalServerError)
			}
			return
		}

		var NewResponse DeviceOwnerResponse
		NewResponse.AccountID = row.AccountID.String()
		NewResponse.Login = row.Login
		NewResponse.DisplayName = row.Login
		if row.DisplayName.Valid && row.DisplayName.String != "" {
			NewResponse.DisplayName = row.DisplayName.String
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(NewResponse)
	}
}
