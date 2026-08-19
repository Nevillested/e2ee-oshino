package api

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"server/internal/db"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

type ReportRequest struct {
	ReportedDeviceID string `json:"reported_device_id"`
	MessageText      string `json:"message_text"`
	Reason           string `json:"reason"`
}

// жалоба на сообщение — переписка E2E-зашифрована, сервер физически не
// видит её содержимое, поэтому текст добровольно присылает сам
// пожаловавшийся клиент (то же самое, что видно в его собственном пузыре
// сообщения). *_login сохраняются текстовым снимком отдельно от *_account_id
// (ON DELETE SET NULL) — жалоба должна остаться читаемой в admin-утилите,
// даже если один из аккаунтов к тому моменту уже удалён.
func NewReportHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var session, tokErr = CheckToken(w, r, queries)
		if tokErr != nil {
			log.Printf("ошибка проверки токена: %v", tokErr)
			return
		}

		var req ReportRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "Ошибка декодирования JSON", http.StatusBadRequest)
			return
		}

		messageText := strings.TrimSpace(req.MessageText)
		if req.ReportedDeviceID == "" || messageText == "" {
			http.Error(w, "Не хватает данных для жалобы", http.StatusBadRequest)
			return
		}

		reporterAccount, err := queries.GetAccountByID(r.Context(), session.AccountID)
		if err != nil {
			http.Error(w, "Ошибка получения аккаунта", http.StatusInternalServerError)
			return
		}

		var reportedDeviceUUID pgtype.UUID
		if err := reportedDeviceUUID.Scan(req.ReportedDeviceID); err != nil {
			http.Error(w, "Ошибка конвертации Device ID", http.StatusBadRequest)
			return
		}
		reportedOwner, err := queries.GetLoginByDeviceID(r.Context(), reportedDeviceUUID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				http.Error(w, "Устройство не найдено", http.StatusNotFound)
				return
			}
			http.Error(w, "Ошибка поиска владельца устройства", http.StatusInternalServerError)
			return
		}

		var reasonText pgtype.Text
		if reason := strings.TrimSpace(req.Reason); reason != "" {
			reasonText = pgtype.Text{String: reason, Valid: true}
		}

		params := db.CreateReportParams{
			ReporterAccountID: session.AccountID,
			ReporterLogin:     reporterAccount.Login,
			ReportedAccountID: reportedOwner.AccountID,
			ReportedLogin:     reportedOwner.Login,
			MessageText:       messageText,
			Reason:            reasonText,
		}
		if err := queries.CreateReport(r.Context(), params); err != nil {
			log.Printf("report: ошибка сохранения жалобы: %v", err)
			http.Error(w, "Ошибка сохранения жалобы", http.StatusInternalServerError)
			return
		}

		log.Printf("report: %s пожаловался на %s", reporterAccount.Login, reportedOwner.Login)
		w.WriteHeader(http.StatusOK)
	}
}
