// check_project_services.go — пункт меню "Проверить состояние служб
// проекта" в этой же утилите (см. main.go). Список служб и портов сверен
// по факту с сервером (systemctl list-units, ss -tlnp), а не угадан —
// смотрит на всё, от чего реально зависит работа приложения:
//   - systemd-служба самого Go-сервера (oshinobu-server) — и отдельно
//     HTTP-запрос к его собственному /health, раз уж он есть: "процесс
//     жив" и "отвечает на запросы" — разные вещи, процесс может висеть
//     задеадлоченным, оставаясь formally "active" для systemd;
//   - nginx — реверс-прокси перед oshinobu-server (порты 80/443);
//   - PostgreSQL — на этой же VPS (postgresql@18-main), слушает на
//     127.0.0.1:5432;
//   - coturn — TURN/STUN-сервер для звонков (порт 3478);
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
// Сознательно НЕ проверяются: общесистемные службы ОС (ssh, cron, chrony,
// fail2ban, cloud-init и т.п.) — они не специфичны для проекта, это
// заботы обычного администрирования сервера, а не эта утилита.
//
// Все проверки — только чтение/сетевые пробы, ничего не меняют.
package main

import (
	"context"
	"fmt"
	"net"
	"net/http"
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
	checkAppHealth(ctx)
	checkSystemdService("nginx")
	checkSystemdService("postgresql@18-main")
	checkPostgres(ctx)
	checkSystemdService("coturn")
	checkSystemdService("e2ee-frps")
	checkMinio(ctx)
	checkSMTP()

	fmt.Println()
}

// checkAppHealth — реальный HTTP-запрос к собственному /health сервера
// (см. api.NewHealthHandler в main.go), в обход nginx, напрямую на
// localhost:8080 — тот же порт, что слушает сам процесс (см. ss -tlnp на
// сервере). Отличает "процесс жив по мнению systemd" от "реально отвечает
// на запросы".
func checkAppHealth(ctx context.Context) {
	ctxTimeout, cancel := context.WithTimeout(ctx, serviceCheckTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctxTimeout, http.MethodGet, "http://localhost:8080/health", nil)
	if err != nil {
		printResult("oshinobu-server /health", false, err.Error())
		return
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		printResult("oshinobu-server /health", false, err.Error())
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		printResult("oshinobu-server /health", false, fmt.Sprintf("ответил статусом %d", resp.StatusCode))
		return
	}
	printResult("oshinobu-server /health", true, "отвечает 200 OK")
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
