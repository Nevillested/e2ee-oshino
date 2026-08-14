package api

import (
	"encoding/json"
	"net/http"
	"server/internal/db"

	"github.com/jackc/pgx/v5/pgtype"
)

type ChatMuteRequest struct {
	PeerAccountID string `json:"peer_account_id"`
}

func NewMuteChatHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var Session, err = CheckToken(w, r, queries)
		if err != nil {
			return
		}

		var Req ChatMuteRequest
		if DecodeErr := json.NewDecoder(r.Body).Decode(&Req); DecodeErr != nil {
			http.Error(w, "Ошибка декодирования JSON", http.StatusBadRequest)
			return
		}

		var PeerID pgtype.UUID
		if ScanErr := PeerID.Scan(Req.PeerAccountID); ScanErr != nil {
			http.Error(w, "Ошибка конвертации peer_account_id", http.StatusBadRequest)
			return
		}

		var SqlErr = queries.MuteChat(r.Context(), db.MuteChatParams{
			AccountID:     Session.AccountID,
			PeerAccountID: PeerID,
		})
		if SqlErr != nil {
			http.Error(w, "Ошибка сохранения мьюта", http.StatusInternalServerError)
			return
		}

		w.WriteHeader(http.StatusOK)
	}
}

func NewUnmuteChatHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var Session, err = CheckToken(w, r, queries)
		if err != nil {
			return
		}

		var Req ChatMuteRequest
		if DecodeErr := json.NewDecoder(r.Body).Decode(&Req); DecodeErr != nil {
			http.Error(w, "Ошибка декодирования JSON", http.StatusBadRequest)
			return
		}

		var PeerID pgtype.UUID
		if ScanErr := PeerID.Scan(Req.PeerAccountID); ScanErr != nil {
			http.Error(w, "Ошибка конвертации peer_account_id", http.StatusBadRequest)
			return
		}

		var SqlErr = queries.UnmuteChat(r.Context(), db.UnmuteChatParams{
			AccountID:     Session.AccountID,
			PeerAccountID: PeerID,
		})
		if SqlErr != nil {
			http.Error(w, "Ошибка снятия мьюта", http.StatusInternalServerError)
			return
		}

		w.WriteHeader(http.StatusOK)
	}
}

type MutedPeersResponse struct {
	PeerAccountIDs []string `json:"peer_account_ids"`
}

// Список замьюченных собеседников — клиент вызывает при старте/логине,
// чтобы восстановить локальное отображение (перечёркнутый значок звука в
// списке чатов) без похода в БД на каждый чат по отдельности.
func NewGetMutedChatsHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var Session, err = CheckToken(w, r, queries)
		if err != nil {
			return
		}

		var Rows, SqlErr = queries.GetMutedPeers(r.Context(), Session.AccountID)
		if SqlErr != nil {
			http.Error(w, "Ошибка получения списка мьютов", http.StatusInternalServerError)
			return
		}

		var Resp MutedPeersResponse
		Resp.PeerAccountIDs = make([]string, 0, len(Rows))
		for _, id := range Rows {
			Resp.PeerAccountIDs = append(Resp.PeerAccountIDs, id.String())
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(Resp)
	}
}
