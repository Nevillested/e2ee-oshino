package api

import (
	"context"
	"log"
	"server/internal/db"
	"time"

	"github.com/jackc/pgx/v5/pgtype"
)

// pendingMessageMaxAge — сколько держать недоставленное сообщение в очереди
// офлайн-доставки, прежде чем считать получателя окончательно потерянным.
// У pending_messages нет TTL/уборки вообще: устройство, навсегда переставшее
// заходить в сеть (удалённый аккаунт, заброшенный тестовый девайс), копит
// очередь бесконечно — единственное, что её чистит, это ON DELETE CASCADE
// при удалении самого устройства из devices.
const pendingMessageMaxAge = 30 * 24 * time.Hour

// StartPendingMessageCleanup — раз в сутки подчищает то, что явно никто уже
// не заберёт. 30 дней — с большим запасом даже для человека, который
// уходил в длительный отпуск без интернета: обычная реальная переписка
// доставляется за секунды-минуты после реконнекта (см. websocket.go), а не
// висит неделями.
func StartPendingMessageCleanup(queries *db.Queries) {
	go func() {
		cleanupPendingMessagesOnce(queries)
		ticker := time.NewTicker(24 * time.Hour)
		defer ticker.Stop()
		for range ticker.C {
			cleanupPendingMessagesOnce(queries)
		}
	}()
}

func cleanupPendingMessagesOnce(queries *db.Queries) {
	cutoff := pgtype.Timestamptz{
		Time:             time.Now().Add(-pendingMessageMaxAge),
		InfinityModifier: pgtype.Finite,
		Valid:            true,
	}
	if err := queries.DeleteOldPendingMessages(context.Background(), cutoff); err != nil {
		log.Printf("ошибка очистки устаревших pending_messages: %v", err)
	}
}
