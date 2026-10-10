package api

import (
	"bufio"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// AppVersion — единственная допустимая версия клиента. Приложение с любой
// другой версией (старше или новее) сервер не обслуживает: ответ 426 с этой
// же информацией, клиент показывает экран "обновите приложение".
//
// Номер берётся из app-version.properties в корне репозитория (versionCode) —
// того же файла, по которому собирается Android-клиент: поднял версию, закоммитил,
// deploy.sh — и сервер требует новую, без правки .env. Нет файла или номера —
// проверка выключена. Остальное — переменными окружения:
//
//	APP_APK_DIR      — папка, где лежит oshinobu.apk той же версии: сервер сам
//	                   раздаёт его по GET /app/apk тем, кто ставил не из Google Play;
//	APP_APK_URL      — APK лежит где-то ещё: полный адрес вместо /app/apk.
//
// Установленные из Play обновляются через Play — им apk_url не нужен.
type AppVersion struct {
	VersionCode int    `json:"version_code"`
	ApkURL      string `json:"apk_url"`
	ApkDir      string `json:"-"`
}

// ApkFileName — имя APK в APP_APK_DIR.
const ApkFileName = "oshinobu.apk"

// ApkPath — маршрут, по которому сервер раздаёт APK из APP_APK_DIR.
const ApkPath = "/app/apk"

// AppVersionHeader — заголовок, в котором клиент сообщает свой versionCode.
const AppVersionHeader = "X-App-Version"

// AppVersionFile — общий с клиентом файл версии, относительно рабочей папки
// сервера (server/, см. WorkingDirectory в systemd-юните).
const AppVersionFile = "../app-version.properties"

func LoadAppVersion(versionFile string) AppVersion {
	if os.Getenv("APP_VERSION_CODE") != "" {
		log.Printf("app version: APP_VERSION_CODE в .env больше не используется — версия берётся из %s; строку можно удалить", versionFile)
	}
	return AppVersion{VersionCode: readVersionCode(versionFile), ApkURL: os.Getenv("APP_APK_URL"), ApkDir: os.Getenv("APP_APK_DIR")}
}

// readVersionCode — versionCode из файла вида key=value (# — комментарии);
// не прочитался — 0 (проверка выключена), с записью в лог.
func readVersionCode(path string) int {
	f, err := os.Open(path)
	if err != nil {
		log.Printf("app version: %v — проверка версии выключена", err)
		return 0
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		key, value, ok := strings.Cut(strings.TrimSpace(scanner.Text()), "=")
		if !ok || strings.TrimSpace(key) != "versionCode" {
			continue
		}
		code, err := strconv.Atoi(strings.TrimSpace(value))
		if err != nil {
			log.Printf("app version: versionCode в %s не число (%q) — проверка версии выключена", path, value)
			return 0
		}
		return code
	}
	log.Printf("app version: в %s нет versionCode — проверка версии выключена", path)
	return 0
}

// apkFile — путь к APK в APP_APK_DIR, если он там лежит.
func (v AppVersion) apkFile() (string, bool) {
	if v.ApkDir == "" {
		return "", false
	}
	path := filepath.Join(v.ApkDir, ApkFileName)
	info, err := os.Stat(path)
	return path, err == nil && info.Mode().IsRegular()
}

// withApkURL — откуда клиенту качать APK: явный APP_APK_URL, иначе свой
// /app/apk (относительный — клиент дополнит адресом сервера), но только
// если файл на месте; проверяется на каждый запрос — APK можно выложить
// без перезапуска сервера.
func (v AppVersion) withApkURL() AppVersion {
	if v.ApkURL == "" {
		if _, ok := v.apkFile(); ok {
			v.ApkURL = ApkPath
		}
	}
	return v
}

func (v AppVersion) writeJSON(w http.ResponseWriter, status int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v.withApkURL())
}

// NewAppVersionHandler — GET /app/version: какая версия сейчас обязательна.
func NewAppVersionHandler(v AppVersion) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		v.writeJSON(w, http.StatusOK)
	}
}

// NewAppApkHandler — GET /app/apk: сам APK из APP_APK_DIR (с поддержкой
// докачки через Range); нет файла — 404.
func NewAppApkHandler(v AppVersion) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		path, ok := v.apkFile()
		if !ok {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/vnd.android.package-archive")
		w.Header().Set("Content-Disposition", `attachment; filename="`+ApkFileName+`"`)
		http.ServeFile(w, r, path)
	}
}

// versionExempt — маршруты, доступные любой версии клиента:
//   - /app/version, /app/apk — устаревшему клиенту надо узнать, что он устарел,
//     и откуда-то скачать новую версию;
//   - /session/check — только сверяет токен, ничего не отдаёт; клиенты 1.0.0+44
//     и +45 считали ЛЮБОЙ не-200 ответ на него (в т. ч. 426) отменой сессии и
//     выходили из аккаунта со стиранием ключей — при смене обязательной версии
//     такой клиент обязан получить здесь честный ответ;
//   - /health.
var versionExempt = map[string]bool{
	"/app/version":   true,
	ApkPath:          true,
	"/session/check": true,
	"/health":        true,
}

// RequireAppVersion пропускает к остальным маршрутам только клиентов с
// обязательной версией (кроме versionExempt).
func RequireAppVersion(v AppVersion, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if v.VersionCode == 0 || versionExempt[r.URL.Path] {
			next.ServeHTTP(w, r)
			return
		}
		client, err := strconv.Atoi(r.Header.Get(AppVersionHeader))
		if err != nil || client != v.VersionCode {
			log.Printf("app version: отказ %s %s — версия клиента %q, нужна %d", r.Method, r.URL.Path, r.Header.Get(AppVersionHeader), v.VersionCode)
			v.writeJSON(w, http.StatusUpgradeRequired)
			return
		}
		next.ServeHTTP(w, r)
	})
}
