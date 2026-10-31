package api

import (
	"context"
	"log"
	"server/internal/db"
	"server/internal/push"

	"github.com/jackc/pgx/v5/pgtype"
)

// sendPush — разбудить устройство пушем: Android — через FCM, iOS — через
// APNs (звонок — VoIP-токен, остальное — обычный). У устройства есть токен
// одного из видов; недействительный APNs-токен забываем.
func sendPush(ctx context.Context, queries *db.Queries, device pgtype.UUID, pushType push.PushType, extra map[string]string) {
	if token, err := queries.GetPushTokenByDevice(ctx, device); err == nil {
		push.SendDataPush(ctx, token.FcmToken, pushType, extra)
	}
	tokens, err := queries.GetApnsTokensByDevice(ctx, device)
	if err != nil {
		return
	}
	target := tokens.AlertToken
	if pushType == push.TypeCall {
		target = tokens.VoipToken
	}
	if !target.Valid {
		return
	}
	if push.SendAPNs(ctx, target.String, tokens.Sandbox, pushType, extra).Gone {
		log.Printf("push: APNs-токен устройства недействителен — удалён")
		if err := queries.DeleteApnsTokensByDevice(ctx, device); err != nil {
			log.Printf("push: не удалось удалить APNs-токен: %v", err)
		}
	}
}
