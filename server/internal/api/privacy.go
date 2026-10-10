package api

import (
	"context"

	"server/internal/db"

	"github.com/jackc/pgx/v5/pgtype"
)

// Блокировка (в любую сторону) скрывает друг от друга не только переписку
// и звонки, но и всё, что видно о человеке: фото, статус, день рождения,
// "в сети"/"был(а) в сети", "печатает…" и сигналы об изменении профиля —
// поверх обычных уровней приватности (никто / все / только контакты).

// blockedBetween — заблокировал ли кто-то из двух аккаунтов другого. Ошибка
// базы — считаем заблокированным: для приватности лучше лишний раз скрыть,
// чем показать.
func blockedBetween(ctx context.Context, queries *db.Queries, a, b pgtype.UUID) bool {
	blocked, err := queries.IsBlockedEitherWay(ctx, db.IsBlockedEitherWayParams{AccountID: a, PeerAccountID: b})
	return err != nil || blocked
}

// dropPresenceBetween — после блокировки снять взаимные подписки на статус
// между всеми устройствами пары: иначе уже открытый чат продолжал бы
// получать живые "в сети"/"не в сети" до переподключения.
func dropPresenceBetween(ctx context.Context, queries *db.Queries, registry *ConnectionRegistry, a, b pgtype.UUID) {
	devicesA, errA := queries.GetDevicesByAccount(ctx, a)
	devicesB, errB := queries.GetDevicesByAccount(ctx, b)
	if errA != nil || errB != nil {
		return
	}
	for _, da := range devicesA {
		for _, dbDevice := range devicesB {
			registry.UnsubscribePresence(da.ID.String(), dbDevice.ID.String())
			registry.UnsubscribePresence(dbDevice.ID.String(), da.ID.String())
		}
	}
}
