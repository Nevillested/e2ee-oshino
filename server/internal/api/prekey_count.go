package api

import (
	"encoding/json"
	"log"
	"net/http"
	"server/internal/db"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

type PrekeyCountResponse struct {
	Remaining int64 `json:"remaining"`
}

// NewGetPrekeyCountHandler — GET /devices/{device_id}/prekey-count. Клиент
// дёргает это при каждом заходе на главный экран (см. home_placeholder_screen.dart
// _connect()), чтобы вовремя пополнить one-time-prekeys, пока их не осталось
// 0 — раньше пополнения не было вообще, ключи загружались один раз при
// регистрации устройства и потихоньку расходовались навсегда.
func NewGetPrekeyCountHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var Session, ErrTokCheck = CheckToken(w, r, queries)
		if ErrTokCheck != nil {
			log.Printf("ошибка проверки токена: %v", ErrTokCheck)
			return
		}

		var deviceIDStr string = r.PathValue("device_id")
		var DeviceID pgtype.UUID
		if ScanUuidErr := DeviceID.Scan(deviceIDStr); ScanUuidErr != nil {
			http.Error(w, "Ошибка конвертации Device ID", http.StatusBadRequest)
			return
		}

		// Тот же самый принцип, что и в upload_prekeys.go — считать остаток
		// можно только для СВОЕГО устройства, не для чужого.
		var owner, OwnerErr = queries.GetLoginByDeviceID(r.Context(), DeviceID)
		if OwnerErr != nil {
			if OwnerErr == pgx.ErrNoRows {
				http.Error(w, "Устройство не найдено", http.StatusNotFound)
			} else {
				http.Error(w, "Ошибка проверки владельца устройства", http.StatusInternalServerError)
			}
			return
		}
		if owner.AccountID != Session.AccountID {
			http.Error(w, "Устройство принадлежит другому аккаунту", http.StatusForbidden)
			return
		}

		count, CountErr := queries.CountUnusedOneTimePrekeys(r.Context(), DeviceID)
		if CountErr != nil {
			http.Error(w, "Ошибка подсчёта prekeys", http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(PrekeyCountResponse{Remaining: count})
	}
}
