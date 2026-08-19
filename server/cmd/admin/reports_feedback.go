// reports_feedback.go — два пункта меню этой же утилиты (см. main.go):
// посмотреть жалобы на сообщения и отзывы обратной связи, с возможностью
// пометить конкретную запись как рассмотренную (reviewed_at) — чтобы при
// следующем заходе сразу было видно, что уже разобрано, а что ещё нет.
// Переписка E2E-зашифрована, поэтому текст в этих таблицах — только то,
// что пользователь сам добровольно указал в момент жалобы/отзыва (см.
// server/internal/api/report.go, feedback.go).
package main

import (
	"bufio"
	"context"
	"fmt"
	"server/internal/db"
	"strconv"
	"strings"
)

func runListReports(ctx context.Context, queries *db.Queries, reader *bufio.Reader) {
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
	for i, row := range rows {
		created := row.CreatedAt.Time.Format("2006-01-02 15:04")
		status := "новая"
		if row.ReviewedAt.Valid {
			status = "рассмотрена " + row.ReviewedAt.Time.Format("2006-01-02 15:04")
		}
		fmt.Printf("%d) [%s] %s пожаловался на %s — %s\n", i+1, created, row.ReporterLogin, row.ReportedLogin, status)
		fmt.Printf("   Сообщение: %s\n", row.MessageText)
		if row.Reason.Valid && row.Reason.String != "" {
			fmt.Printf("   Комментарий: %s\n", row.Reason.String)
		}
	}

	fmt.Print("\nПометить как рассмотренную — введи номер (Enter, чтобы пропустить): ")
	choice, err := reader.ReadString('\n')
	if err != nil {
		return
	}
	choice = strings.TrimSpace(choice)
	if choice == "" {
		return
	}
	idx, err := strconv.Atoi(choice)
	if err != nil || idx < 1 || idx > len(rows) {
		fmt.Println("Не понял номер, пропущено.")
		return
	}
	if err := queries.MarkReportReviewed(ctx, rows[idx-1].ID); err != nil {
		fmt.Printf("Ошибка обновления: %v\n", err)
		return
	}
	fmt.Println("Отмечено как рассмотренная.")
}

func runListFeedback(ctx context.Context, queries *db.Queries, reader *bufio.Reader) {
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
	for i, row := range rows {
		created := row.CreatedAt.Time.Format("2006-01-02 15:04")
		status := "новый"
		if row.ReviewedAt.Valid {
			status = "рассмотрен " + row.ReviewedAt.Time.Format("2006-01-02 15:04")
		}
		fmt.Printf("%d) [%s] %s — %s\n   %s\n", i+1, created, row.AccountLogin, status, row.Message)
	}

	fmt.Print("\nПометить как рассмотренный — введи номер (Enter, чтобы пропустить): ")
	choice, err := reader.ReadString('\n')
	if err != nil {
		return
	}
	choice = strings.TrimSpace(choice)
	if choice == "" {
		return
	}
	idx, err := strconv.Atoi(choice)
	if err != nil || idx < 1 || idx > len(rows) {
		fmt.Println("Не понял номер, пропущено.")
		return
	}
	if err := queries.MarkFeedbackReviewed(ctx, rows[idx-1].ID); err != nil {
		fmt.Printf("Ошибка обновления: %v\n", err)
		return
	}
	fmt.Println("Отмечено как рассмотренный.")
}
