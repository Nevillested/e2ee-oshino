// reports_feedback.go — два read-only пункта меню этой же утилиты (см.
// main.go): посмотреть жалобы на сообщения и отзывы обратной связи.
// Переписка E2E-зашифрована, поэтому текст в этих таблицах — только то,
// что пользователь сам добровольно указал в момент жалобы/отзыва (см.
// server/internal/api/report.go, feedback.go).
package main

import (
	"context"
	"fmt"
	"server/internal/db"
)

func runListReports(ctx context.Context, queries *db.Queries) {
	rows, err := queries.ListReports(ctx)
	if err != nil {
		fmt.Printf("Ошибка чтения жалоб из базы: %v\n", err)
		return
	}
	if len(rows) == 0 {
		fmt.Println("Жалоб пока нет.")
		return
	}

	fmt.Println()
	for _, row := range rows {
		created := row.CreatedAt.Time.Format("2006-01-02 15:04")
		fmt.Printf("[%s] %s пожаловался на %s\n", created, row.ReporterLogin, row.ReportedLogin)
		fmt.Printf("  Сообщение: %s\n", row.MessageText)
		if row.Reason.Valid && row.Reason.String != "" {
			fmt.Printf("  Комментарий: %s\n", row.Reason.String)
		}
		fmt.Println()
	}
}

func runListFeedback(ctx context.Context, queries *db.Queries) {
	rows, err := queries.ListFeedback(ctx)
	if err != nil {
		fmt.Printf("Ошибка чтения отзывов из базы: %v\n", err)
		return
	}
	if len(rows) == 0 {
		fmt.Println("Отзывов пока нет.")
		return
	}

	fmt.Println()
	for _, row := range rows {
		created := row.CreatedAt.Time.Format("2006-01-02 15:04")
		fmt.Printf("[%s] %s:\n  %s\n\n", created, row.AccountLogin, row.Message)
	}
}
