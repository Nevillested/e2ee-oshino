// cmd/admin — ручная утилита поддержки: сброс пароля или TOTP-секрета
// конкретному аккаунту по логину, когда пользователь потерял доступ и
// написал напрямую в support@oshino.space (не через автоматическое
// восстановление по почте — у него либо не была указана почта в
// настройках, либо он забыл и её тоже).
//
// ВАЖНО: это НЕ HTTP-эндпоинт и никогда не должно им стать — запускать
// только вручную по SSH прямо на сервере, после того как ты сам убедился
// (в переписке), что это действительно владелец аккаунта. Открытый в сеть
// эндпоинт с таким функционалом — готовый способ угнать любой аккаунт.
//
// Использование — из директории cmd/admin/ (там же, где лежит этот файл):
//
//	go run .
//
// Именно "." (весь пакет в директории), а не "go run main.go" — в пакете
// теперь два файла (см. check_project_services.go), а "go run main.go"
// компилирует ТОЛЬКО перечисленный файл, без остальных из того же пакета.
//
// .env ищется не по текущей рабочей директории, а рядом с самим этим
// файлом (см. envPath) — так утилиту можно запускать откуда угодно, не
// обязательно предварительно переходя в server/.
package main

import (
	"bufio"
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"server/internal/auth"
	"server/internal/db"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/joho/godotenv"
	"github.com/pquerna/otp/totp"
	"golang.org/x/term"
)

// envPath — .env всегда лежит в server/.env, а этот файл — в
// server/cmd/admin/main.go, то есть на два уровня выше. runtime.Caller(0)
// даёт путь к ИСХОДНИКУ (даже при запуске через "go run"), а не к текущей
// рабочей директории — поэтому утилита находит .env независимо от того,
// откуда её реально запустили.
func envPath() string {
	_, thisFile, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(thisFile), "..", "..", ".env")
}

func main() {
	path := envPath()
	if _, err := os.Stat(path); err != nil {
		fmt.Printf("Файл .env не найден (%s) — без него не узнать DATABASE_URL.\n", path)
		fmt.Println("Завершение через 5 секунд...")
		time.Sleep(5 * time.Second)
		os.Exit(1)
	}
	if err := godotenv.Load(path); err != nil {
		fmt.Printf("Не удалось прочитать .env (%s): %v\n", path, err)
		fmt.Println("Завершение через 5 секунд...")
		time.Sleep(5 * time.Second)
		os.Exit(1)
	}

	ctx := context.Background()
	pool, err := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		log.Fatalf("ошибка подключения к базе данных: %v", err)
	}
	defer pool.Close()
	queries := db.New(pool)

	reader := bufio.NewReader(os.Stdin)
	runMenu(ctx, queries, reader)
}

// runMenu — главный цикл: после любого действия (успех, отмена, ошибка —
// например, логин не нашёлся) возвращается обратно к выбору, а не завершает
// утилиту. Выход — только явным пунктом меню.
func runMenu(ctx context.Context, queries *db.Queries, reader *bufio.Reader) {
	for {
		fmt.Println()
		fmt.Println("=== Oshinobu — админ-утилита ===")
		fmt.Println("1) Сменить пароль аккаунта")
		fmt.Println("2) Сбросить TOTP-секрет (код аутентификатора)")
		fmt.Println("3) Проверить состояние служб проекта")
		fmt.Println("4) Выход")
		fmt.Print("Выбор: ")

		// Ошибка чтения (например, stdin неожиданно закрылся — EOF) не
		// должна крутить цикл вхолостую бесконечно: раньше именно так и
		// происходило, ReadString возвращал пустую строку раз за разом.
		choice, err := reader.ReadString('\n')
		if err != nil {
			fmt.Println("\nВвод прерван, завершение.")
			return
		}
		switch strings.TrimSpace(choice) {
		case "1":
			runAction(ctx, queries, reader, resetPassword)
		case "2":
			runAction(ctx, queries, reader, resetTOTP)
		case "3":
			runCheckServices(ctx)
		case "4":
			fmt.Println("Пока.")
			return
		default:
			fmt.Println("Не понял выбор, попробуй ещё раз.")
		}
	}
}

// runAction — общая часть для обоих действий: спросить логин, найти
// аккаунт, передать его в конкретную функцию. Не найден аккаунт — не
// падение всей утилиты, просто сообщение и назад в меню.
func runAction(
	ctx context.Context,
	queries *db.Queries,
	reader *bufio.Reader,
	action func(ctx context.Context, queries *db.Queries, reader *bufio.Reader, account db.Account),
) {
	fmt.Print("Логин пользователя: ")
	loginRaw, err := reader.ReadString('\n')
	if err != nil {
		fmt.Println("\nВвод прерван, отменено.")
		return
	}
	login := strings.TrimSpace(loginRaw)
	if login == "" {
		fmt.Println("Пустой логин, отменено.")
		return
	}

	account, err := queries.GetAccountByLogin(ctx, login)
	if err != nil {
		fmt.Printf("Пользователь %q не найден: %v\n", login, err)
		return
	}

	action(ctx, queries, reader, account)
}

func confirm(reader *bufio.Reader, prompt string) bool {
	fmt.Printf("%s [yes/N]: ", prompt)
	line, err := reader.ReadString('\n')
	if err != nil {
		return false
	}
	return strings.TrimSpace(strings.ToLower(line)) == "yes"
}

func resetPassword(ctx context.Context, queries *db.Queries, reader *bufio.Reader, account db.Account) {
	fmt.Printf("Смена пароля для %q (id: %s)\n", account.Login, account.ID)
	if !confirm(reader, "Точно продолжить?") {
		fmt.Println("Отменено.")
		return
	}

	fmt.Print("Новый пароль: ")
	pw1, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Println()
	if err != nil {
		fmt.Printf("Не удалось прочитать пароль: %v\n", err)
		return
	}

	fmt.Print("Повторите новый пароль: ")
	pw2, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Println()
	if err != nil {
		fmt.Printf("Не удалось прочитать пароль: %v\n", err)
		return
	}

	if string(pw1) != string(pw2) {
		fmt.Println("Пароли не совпадают, отменено.")
		return
	}
	if PolicyErr := auth.ValidatePassword(string(pw1)); PolicyErr != nil {
		fmt.Printf("%v, отменено.\n", PolicyErr)
		return
	}

	hash, err := auth.HashPassword(string(pw1))
	if err != nil {
		fmt.Printf("Ошибка хеширования пароля: %v\n", err)
		return
	}

	err = queries.UpdateAccountPasswordHash(ctx, db.UpdateAccountPasswordHashParams{
		ID:           account.ID,
		PasswordHash: hash,
	})
	if err != nil {
		fmt.Printf("Ошибка записи в базу: %v\n", err)
		return
	}

	fmt.Printf("Готово — пароль для %q обновлён.\n", account.Login)
}

func resetTOTP(ctx context.Context, queries *db.Queries, reader *bufio.Reader, account db.Account) {
	fmt.Printf("Сброс TOTP-секрета для %q (id: %s)\n", account.Login, account.ID)
	fmt.Println("Старый код из аутентификатора у пользователя после этого перестанет работать.")
	if !confirm(reader, "Точно продолжить?") {
		fmt.Println("Отменено.")
		return
	}

	key, err := totp.Generate(totp.GenerateOpts{Issuer: "OShinobu", AccountName: account.Login})
	if err != nil {
		fmt.Printf("Ошибка генерации TOTP-ключа: %v\n", err)
		return
	}

	err = queries.UpdateAccountTotpSecret(ctx, db.UpdateAccountTotpSecretParams{
		ID:         account.ID,
		TotpSecret: key.Secret(),
	})
	if err != nil {
		fmt.Printf("Ошибка записи в базу: %v\n", err)
		return
	}

	fmt.Println()
	fmt.Println("Готово. Передай пользователю ОДИН из вариантов ниже — лично, в переписке,")
	fmt.Println("никуда больше не публикуя (это ключ ко входу в его аккаунт):")
	fmt.Println()
	fmt.Printf("  Ключ для ручного ввода (в аутентификаторе: 'Ввести код вручную'):\n    %s\n\n", key.Secret())
	fmt.Printf("  Либо сгенерируй ему QR ЛОКАЛЬНО (например: qrencode -t ansiutf8 \"<ссылка>\"),\n")
	fmt.Printf("  не отправляя ссылку в сторонние онлайн-генераторы QR — она равносильна паролю:\n    %s\n", key.URL())
}
