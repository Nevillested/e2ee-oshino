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

// AppVersion — какие версии клиента обслуживает сервер.
//
//   - VersionCode — последняя выпущенная версия: клиент, у которого установлена
//     старше, показывает на главном экране кнопку «Обновить приложение» (без
//     блокировки — старая версия продолжает работать);
//   - MinVersionCode — самая старая версия, которую сервер ещё обслуживает:
//     клиенту старше неё любой запрос (кроме versionExempt) отвечает 426 с этой
//     же информацией. Новее последней — пропускается (сборку уже выпустили в
//     Play, а сервер ещё не задеплоен).
//
// Оба номера берутся из app-version.properties в корне репозитория (versionCode,
// minVersionCode) — того же файла, по которому собирается Android-клиент: поднял
// версию, закоммитил, deploy.sh — без правки .env. Нет minVersionCode — старые
// версии не отсекаются. Остальное — переменными окружения:
//
//	APP_APK_DIR      — папка, где лежит oshinobu.apk последней версии: сервер сам
//	                   раздаёт его по GET /app/apk тем, кто ставил не из Google Play;
//	APP_APK_URL      — APK лежит где-то ещё: полный адрес вместо /app/apk.
//
// Установленные из Play обновляются через Play — им apk_url не нужен.
type AppVersion struct {
	VersionCode    int    `json:"version_code"`
	MinVersionCode int    `json:"min_version_code"`
	ApkURL         string `json:"apk_url"`
	ApkDir         string `json:"-"`
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
	props := readProperties(versionFile)
	v := AppVersion{
		VersionCode:    propertyInt(versionFile, props, "versionCode"),
		MinVersionCode: propertyInt(versionFile, props, "minVersionCode"),
		ApkURL:         os.Getenv("APP_APK_URL"),
		ApkDir:         os.Getenv("APP_APK_DIR"),
	}
	log.Printf("app version: последняя %d, обслуживаются с %d", v.VersionCode, v.MinVersionCode)
	return v
}

// readProperties — файл вида key=value (# — комментарии); не прочитался — пусто,
// с записью в лог.
func readProperties(path string) map[string]string {
	props := map[string]string{}
	f, err := os.Open(path)
	if err != nil {
		log.Printf("app version: %v", err)
		return props
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(line, "#") {
			continue
		}
		if key, value, ok := strings.Cut(line, "="); ok {
			props[strings.TrimSpace(key)] = strings.TrimSpace(value)
		}
	}
	return props
}

// propertyInt — числовое значение ключа; нет или не число — 0, с записью в лог.
func propertyInt(path string, props map[string]string, key string) int {
	value, ok := props[key]
	if !ok {
		log.Printf("app version: в %s нет %s", path, key)
		return 0
	}
	n, err := strconv.Atoi(value)
	if err != nil {
		log.Printf("app version: %s в %s не число (%q)", key, path, value)
		return 0
	}
	return n
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

// NewAppVersionHandler — GET /app/version: последняя версия, самая старая
// обслуживаемая и откуда взять APK.
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
//     выходили из аккаунта со стиранием ключей — при подъёме minVersionCode
//     такой клиент обязан получить здесь честный ответ;
//   - /health.
var versionExempt = map[string]bool{
	"/app/version":   true,
	ApkPath:          true,
	"/session/check": true,
	"/health":        true,
}

// RequireAppVersion не пускает к остальным маршрутам (кроме versionExempt)
// клиентов старше MinVersionCode и запросы без версии.
func RequireAppVersion(v AppVersion, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if v.MinVersionCode == 0 || versionExempt[r.URL.Path] {
			next.ServeHTTP(w, r)
			return
		}
		client, err := strconv.Atoi(r.Header.Get(AppVersionHeader))
		if err != nil || client < v.MinVersionCode {
			log.Printf("app version: отказ %s %s — версия клиента %q, обслуживаются с %d", r.Method, r.URL.Path, r.Header.Get(AppVersionHeader), v.MinVersionCode)
			v.writeJSON(w, http.StatusUpgradeRequired)
			return
		}
		next.ServeHTTP(w, r)
	})
}
