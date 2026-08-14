package api

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"server/internal/db"

	"github.com/coder/websocket"
	"github.com/jackc/pgx/v5/pgtype"
)

type ContactBlockRequest struct {
	PeerAccountID string `json:"peer_account_id"`
}

// notifyBlockStatusChanged — уведомляет ВСЕ устройства затронутого
// аккаунта, что что-то в блокировках изменилось (без деталей — кто именно,
// в какую сторону: сервер остаётся единственным источником истины, см.
// ApiClient.getBlockedContacts/_refreshBlockStatusFromServer на клиенте,
// сигнал только говорит "перепроверь прямо сейчас, не жди следующего
// подключения"). Устройство в сети — пишем в сокет напрямую, как обычный
// relay; не в сети — кладём в ТУ ЖЕ очередь pending_messages, что и
// обычные зашифрованные сообщения (см. queuePendingMessage в
// websocket.go), и оно само придёт при следующем подключении (см.
// GetPendingMessages в NewWebSocketHandler) — раньше вместо этого сигнал
// для офлайн-устройства просто пропадал, полагаясь на то, что клиент
// сам когда-нибудь спросит сервер заново; теперь доставка гарантирована
// той же дорогой, что и у любого другого сообщения. Без push — как и
// остальные служебные control-сигналы (реакция/пин/удаление), будить
// закрытое приложение ради этого не нужно.
func notifyBlockStatusChanged(ctx context.Context, queries *db.Queries, registry *ConnectionRegistry, accountID pgtype.UUID) {
	devices, err := queries.GetDevicesByAccount(ctx, accountID)
	if err != nil {
		log.Printf("notifyBlockStatusChanged: не удалось получить устройства аккаунта: %v", err)
		return
	}

	msgBytes, err := json.Marshal(WSMsgTo{Type: "block_status_changed"})
	if err != nil {
		return
	}

	for _, device := range devices {
		conn, online := registry.Get(device.ID.String())
		if online {
			if writeErr := conn.Write(ctx, websocket.MessageText, msgBytes); writeErr != nil {
				log.Printf("notifyBlockStatusChanged: ошибка отправки устройству, ставим в очередь: %v", writeErr)
				online = false
			}
		}
		if !online {
			if saveErr := queries.SavePendingMessage(ctx, db.SavePendingMessageParams{
				ToDeviceID: device.ID,
				Ciphertext: string(msgBytes),
			}); saveErr != nil {
				log.Printf("notifyBlockStatusChanged: не удалось поставить сигнал в очередь: %v", saveErr)
			}
		}
	}
}

func NewBlockContactHandler(queries *db.Queries, registry *ConnectionRegistry) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var Session, err = CheckToken(w, r, queries)
		if err != nil {
			return
		}

		var Req ContactBlockRequest
		if DecodeErr := json.NewDecoder(r.Body).Decode(&Req); DecodeErr != nil {
			http.Error(w, "Ошибка декодирования JSON", http.StatusBadRequest)
			return
		}

		var PeerID pgtype.UUID
		if ScanErr := PeerID.Scan(Req.PeerAccountID); ScanErr != nil {
			http.Error(w, "Ошибка конвертации peer_account_id", http.StatusBadRequest)
			return
		}

		var SqlErr = queries.BlockContact(r.Context(), db.BlockContactParams{
			AccountID:     Session.AccountID,
			PeerAccountID: PeerID,
		})
		if SqlErr != nil {
			http.Error(w, "Ошибка сохранения блокировки", http.StatusInternalServerError)
			return
		}

		notifyBlockStatusChanged(r.Context(), queries, registry, PeerID)

		w.WriteHeader(http.StatusOK)
	}
}

func NewUnblockContactHandler(queries *db.Queries, registry *ConnectionRegistry) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var Session, err = CheckToken(w, r, queries)
		if err != nil {
			return
		}

		var Req ContactBlockRequest
		if DecodeErr := json.NewDecoder(r.Body).Decode(&Req); DecodeErr != nil {
			http.Error(w, "Ошибка декодирования JSON", http.StatusBadRequest)
			return
		}

		var PeerID pgtype.UUID
		if ScanErr := PeerID.Scan(Req.PeerAccountID); ScanErr != nil {
			http.Error(w, "Ошибка конвертации peer_account_id", http.StatusBadRequest)
			return
		}

		var SqlErr = queries.UnblockContact(r.Context(), db.UnblockContactParams{
			AccountID:     Session.AccountID,
			PeerAccountID: PeerID,
		})
		if SqlErr != nil {
			http.Error(w, "Ошибка снятия блокировки", http.StatusInternalServerError)
			return
		}

		notifyBlockStatusChanged(r.Context(), queries, registry, PeerID)

		w.WriteHeader(http.StatusOK)
	}
}

type BlockedContactsResponse struct {
	// BlockedByMe — кого заблокировал сам пользователь (надпись первого
	// приоритета в чате с ними на клиенте).
	BlockedByMe []string `json:"blocked_by_me"`
	// BlockingMe — кто заблокировал самого пользователя (надпись второго
	// приоритета, если он сам их не блокировал тоже).
	BlockingMe []string `json:"blocking_me"`
}

// Обе стороны сразу одним запросом — клиент вызывает при старте/логине,
// чтобы восстановить локальное состояние (какая заглушка вместо панели
// сообщений в каждом чате) без похода в БД на каждый чат по отдельности,
// как и с GetMutedChatsHandler.
func NewGetBlockedContactsHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var Session, err = CheckToken(w, r, queries)
		if err != nil {
			return
		}

		var BlockedByMeRows, SqlErr = queries.GetBlockedPeers(r.Context(), Session.AccountID)
		if SqlErr != nil {
			http.Error(w, "Ошибка получения списка блокировок", http.StatusInternalServerError)
			return
		}

		var BlockingMeRows []pgtype.UUID
		BlockingMeRows, SqlErr = queries.GetPeersWhoBlockedMe(r.Context(), Session.AccountID)
		if SqlErr != nil {
			http.Error(w, "Ошибка получения списка блокировок", http.StatusInternalServerError)
			return
		}

		var Resp BlockedContactsResponse
		Resp.BlockedByMe = make([]string, 0, len(BlockedByMeRows))
		for _, id := range BlockedByMeRows {
			Resp.BlockedByMe = append(Resp.BlockedByMe, id.String())
		}
		Resp.BlockingMe = make([]string, 0, len(BlockingMeRows))
		for _, id := range BlockingMeRows {
			Resp.BlockingMe = append(Resp.BlockingMe, id.String())
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(Resp)
	}
}
