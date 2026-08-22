// invite_codes.go — два пункта меню этой же утилиты (см. main.go):
// сгенерировать одноразовый пригласительный код и посмотреть список всех
// уже выданных (использованных и нет). Регистрация в приложении теперь
// закрыта для всех, у кого нет такого кода (см. server/internal/api/register.go)
// — раздаёт их пользователь вручную, лично, кому сочтёт нужным.
package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"math/big"
	"server/internal/db"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

const inviteCodeMaxAttempts = 10

// generateSixDigitCode — 6 случайных цифр (000000..999999), строкой, с
// сохранением ведущих нулей (в отличие от обычного int тут это важно —
// "042817" должно остаться шестизначным, а не стать "42817").
func generateSixDigitCode() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%06d", n.Int64()), nil
}

func runGenerateInviteCode(ctx context.Context, queries *db.Queries) {
	for attempt := 0; attempt < inviteCodeMaxAttempts; attempt++ {
		code, err := generateSixDigitCode()
		if err != nil {
			fmt.Printf("Ошибка генерации кода: %v\n", err)
			return
		}

		_, err = queries.CreateInviteCode(ctx, code)
		if err == nil {
			fmt.Printf("Готово — новый пригласительный код: %s\n", code)
			return
		}

		// UNIQUE-конфликт (такой код уже существует, редко, но возможно на
		// 1 000 000 вариантов) — перегенерировать и попробовать снова; любая
		// другая ошибка — настоящая проблема, дальше пытаться бессмысленно.
		var pgErr *pgconn.PgError
		if !errors.As(err, &pgErr) || pgErr.Code != "23505" {
			fmt.Printf("Ошибка сохранения кода в базу: %v\n", err)
			return
		}
	}
	fmt.Println("Не удалось подобрать свободный код за несколько попыток, попробуй ещё раз.")
}

func runListInviteCodes(ctx context.Context, queries *db.Queries) {
	rows, err := queries.ListInviteCodes(ctx)
	if err != nil {
		fmt.Printf("Ошибка чтения кодов из базы: %v\n", err)
		return
	}
	if len(rows) == 0 {
		fmt.Println("Пригласительных кодов пока нет.")
		return
	}

	fmt.Println()
	for _, row := range rows {
		created := row.CreatedAt.Time.Format("2006-01-02 15:04")
		if !row.UsedAt.Valid {
			fmt.Printf("%s — создан %s — не использован\n", row.Code, created)
			continue
		}
		usedAt := row.UsedAt.Time.Format("2006-01-02 15:04")
		if row.UsedByLogin.Valid {
			fmt.Printf("%s — создан %s — использован: %s (%s)\n", row.Code, created, row.UsedByLogin.String, usedAt)
		} else {
			fmt.Printf("%s — создан %s — использован %s (аккаунт с тех пор удалён)\n", row.Code, created, usedAt)
		}
	}
}

// runDeleteInviteCode — удаляет конкретный код по его 6-значному значению
// (см. список, пункт 5). Если код уже был кем-то использован, удаление
// самой записи НИКАК не откатывает регистрацию — used_by_account_id
// ссылается ON DELETE SET NULL, аккаунт целиком остаётся как есть, пропадает
// только историческая запись о самом коде. Отдельно предупреждаем об этом
// перед подтверждением, чтобы не удалили использованный код по ошибке,
// думая, что это как-то заблокирует уже зарегистрированный аккаунт.
func runDeleteInviteCode(ctx context.Context, queries *db.Queries, reader *bufio.Reader) {
	fmt.Print("Код для удаления (6 цифр): ")
	raw, err := reader.ReadString('\n')
	if err != nil {
		fmt.Println("\nВвод прерван, отменено.")
		return
	}
	code := strings.TrimSpace(raw)
	if code == "" {
		fmt.Println("Пустой код, отменено.")
		return
	}

	row, err := queries.GetInviteCodeByCode(ctx, code)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			fmt.Printf("Код %q не найден.\n", code)
			return
		}
		fmt.Printf("Ошибка чтения кода из базы: %v\n", err)
		return
	}

	if row.UsedAt.Valid {
		fmt.Println("Внимание: этот код уже использован — удаление сотрёт только")
		fmt.Println("саму запись о коде, аккаунт, который по нему зарегистрировался,")
		fmt.Println("никуда не денется.")
	}
	if !confirm(reader, fmt.Sprintf("Точно удалить код %q?", code)) {
		fmt.Println("Отменено.")
		return
	}

	if _, err := queries.DeleteInviteCode(ctx, code); err != nil {
		fmt.Printf("Ошибка удаления из базы: %v\n", err)
		return
	}
	fmt.Printf("Готово — код %q удалён.\n", code)
}
