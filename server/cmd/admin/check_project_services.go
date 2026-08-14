// check_project_services.go — пункт меню "Проверить состояние служб
// проекта" в этой же утилите (см. main.go). Смотрит на всё, от чего
// реально зависит работа приложения:
//   - systemd-служба самого Go-сервера (oshinobu-server);
//   - PostgreSQL — на этой же VPS (postgresql@18-main), просто слушает на
//     приватном интерфейсе;
//   - e2ee-frps — FRP-сервер на этой VPS, принимает туннель от сетевого
//     хранилища в Японии, где реально крутится MinIO; если эта служба
//     упадёт, MinIO станет недоступен даже если сам NAS в полном порядке —
//     отдельная, самая частая точка отказа именно на стороне этой VPS;
//   - MinIO — сам туннель целиком, сквозной проверкой (реальный вызов API
//     через тот же путь, которым ходит приложение);
//   - SMTP-хост почты (mail.hosting.reg.ru) — тот самый порт 587, который
//     раньше резался провайдером, стоит держать под наблюдением на случай,
//     если блокировку внезапно вернут или что-то изменится на их стороне.
//
// Все проверки — только чтение/сетевые пробы, ничего не меняют.
package main

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

const serviceCheckTimeout = 5 * time.Second

func runCheckServices(ctx context.Context) {
	fmt.Println()
	fmt.Println("=== Состояние служб проекта ===")
	fmt.Println()

	checkSystemdService("oshinobu-server")
	checkSystemdService("postgresql@18-main")
	checkPostgres(ctx)
	checkSystemdService("e2ee-frps")
	checkMinio(ctx)
	checkSMTP()

	fmt.Println()
}

// checkSystemdService — active говорит "работает прямо сейчас", enabled —
// "автоматически запустится после перезагрузки сервера". Это два разных
// вопроса: служба может быть включена (enabled), но сейчас не запущена
// (упала), или наоборот — запущена вручную, но не будет поднята сама после
// ребута, если никто не сделал systemctl enable.
func checkSystemdService(name string) {
	active := runSystemctl("is-active", name)
	enabled := runSystemctl("is-enabled", name)

	ok := active == "active" && enabled == "enabled"
	detail := fmt.Sprintf("active=%s, enabled=%s", active, enabled)
	if enabled != "enabled" {
		detail += " — ПОСЛЕ ПЕРЕЗАГРУЗКИ СЕРВЕРА САМА НЕ ЗАПУСТИТСЯ, нужно: sudo systemctl enable " + name
	}

	printResult(fmt.Sprintf("systemd: %s", name), ok, detail)
}

func runSystemctl(args ...string) string {
	out, err := exec.Command("systemctl", args...).Output()
	result := strings.TrimSpace(string(out))
	if err != nil && result == "" {
		return "неизвестно (" + err.Error() + ")"
	}
	return result
}

func checkPostgres(ctx context.Context) {
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		printResult("PostgreSQL", false, "переменная DATABASE_URL не задана в .env")
		return
	}

	ctxTimeout, cancel := context.WithTimeout(ctx, serviceCheckTimeout)
	defer cancel()

	pool, err := pgxpool.New(ctxTimeout, dbURL)
	if err != nil {
		printResult("PostgreSQL", false, err.Error())
		return
	}
	defer pool.Close()

	if err := pool.Ping(ctxTimeout); err != nil {
		printResult("PostgreSQL", false, err.Error())
		return
	}
	printResult("PostgreSQL", true, "подключение и ping прошли успешно")
}

func checkMinio(ctx context.Context) {
	endpoint := os.Getenv("MINIO_ENDPOINT")
	bucket := os.Getenv("MINIO_BUCKET")
	if endpoint == "" {
		printResult("MinIO", false, "переменная MINIO_ENDPOINT не задана в .env")
		return
	}

	client, err := minio.New(endpoint, &minio.Options{
		Creds:  credentials.NewStaticV4(os.Getenv("MINIO_ACCESS_KEY"), os.Getenv("MINIO_SECRET_KEY"), ""),
		Secure: false,
	})
	if err != nil {
		printResult("MinIO", false, err.Error())
		return
	}

	ctxTimeout, cancel := context.WithTimeout(ctx, serviceCheckTimeout)
	defer cancel()

	exists, err := client.BucketExists(ctxTimeout, bucket)
	if err != nil {
		printResult("MinIO", false, err.Error())
		return
	}
	if !exists {
		printResult("MinIO", false, fmt.Sprintf("подключился, но бакет %q не найден", bucket))
		return
	}
	printResult("MinIO", true, fmt.Sprintf("подключение успешно, бакет %q на месте", bucket))
}

// checkSMTP — просто TCP-подключение к почтовому хосту, без реальной
// отправки письма (не хотим слать тестовые письма при каждой проверке) —
// этого достаточно, чтобы поймать ровно ту проблему, что уже была: порт
// блокирован на уровне сети, а не проблему конкретно в приложении.
func checkSMTP() {
	host := os.Getenv("SMTP_HOST")
	port := os.Getenv("SMTP_PORT")
	if host == "" || port == "" {
		printResult("SMTP (почта)", false, "SMTP_HOST/SMTP_PORT не заданы в .env")
		return
	}

	conn, err := net.DialTimeout("tcp", host+":"+port, serviceCheckTimeout)
	if err != nil {
		printResult("SMTP (почта)", false, err.Error())
		return
	}
	_ = conn.Close()
	printResult("SMTP (почта)", true, fmt.Sprintf("%s:%s доступен", host, port))
}

func printResult(name string, ok bool, detail string) {
	status := "✓ OK  "
	if !ok {
		status = "✗ FAIL"
	}
	fmt.Printf("%s %-28s %s\n", status, name, detail)
}
