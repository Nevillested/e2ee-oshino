package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestRequireAppVersion(t *testing.T) {
	ok := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })
	gate := RequireAppVersion(AppVersion{VersionCode: 47, MinVersionCode: 45, ApkURL: "https://example/app.apk"}, ok)

	cases := []struct {
		path, version string
		want          int
	}{
		{"/chats/muted", "47", http.StatusOK},
		// старше последней, но не старше минимальной — обслуживается (кнопка «Обновить» без блокировки)
		{"/chats/muted", "45", http.StatusOK},
		{"/chats/muted", "44", http.StatusUpgradeRequired},
		// новее последней: выпущена в Play, сервер ещё не задеплоен
		{"/chats/muted", "48", http.StatusOK},
		{"/ws", "", http.StatusUpgradeRequired},
		{"/app/version", "", http.StatusOK},
		{"/app/apk", "", http.StatusOK},
		{"/session/check", "44", http.StatusOK},
		{"/health", "", http.StatusOK},
	}
	for _, c := range cases {
		req := httptest.NewRequest(http.MethodGet, c.path, nil)
		if c.version != "" {
			req.Header.Set(AppVersionHeader, c.version)
		}
		rec := httptest.NewRecorder()
		gate.ServeHTTP(rec, req)
		if rec.Code != c.want {
			t.Errorf("%s v=%q: got %d, want %d", c.path, c.version, rec.Code, c.want)
		}
	}

	off := RequireAppVersion(AppVersion{VersionCode: 47}, ok)
	rec := httptest.NewRecorder()
	off.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/chats/muted", nil))
	if rec.Code != http.StatusOK {
		t.Errorf("minVersionCode нет, а запрос отклонён: %d", rec.Code)
	}
}

func versionJSON(t *testing.T, v AppVersion) AppVersion {
	t.Helper()
	rec := httptest.NewRecorder()
	NewAppVersionHandler(v)(rec, httptest.NewRequest(http.MethodGet, "/app/version", nil))
	var got AppVersion
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	return got
}

func TestAppApk(t *testing.T) {
	dir := t.TempDir()
	v := AppVersion{VersionCode: 45, ApkDir: dir}

	// APK ещё не выложен: ссылки нет, раздавать нечего
	if got := versionJSON(t, v); got.ApkURL != "" {
		t.Errorf("APK нет, а apk_url = %q", got.ApkURL)
	}
	rec := httptest.NewRecorder()
	NewAppApkHandler(v)(rec, httptest.NewRequest(http.MethodGet, ApkPath, nil))
	if rec.Code != http.StatusNotFound {
		t.Errorf("APK нет, а ответ %d", rec.Code)
	}

	// выложили — без перезапуска появилась ссылка, файл отдаётся как есть
	if err := os.WriteFile(filepath.Join(dir, ApkFileName), []byte("apk-bytes"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := versionJSON(t, v); got.ApkURL != ApkPath {
		t.Errorf("APK выложен, а apk_url = %q", got.ApkURL)
	}
	rec = httptest.NewRecorder()
	NewAppApkHandler(v)(rec, httptest.NewRequest(http.MethodGet, ApkPath, nil))
	if rec.Code != http.StatusOK || rec.Body.String() != "apk-bytes" {
		t.Errorf("раздача APK: %d %q", rec.Code, rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/vnd.android.package-archive" {
		t.Errorf("Content-Type = %q", ct)
	}

	// явный APP_APK_URL важнее своей раздачи
	v.ApkURL = "https://example/app.apk"
	if got := versionJSON(t, v); got.ApkURL != "https://example/app.apk" {
		t.Errorf("явный адрес потерян: %q", got.ApkURL)
	}
}

func TestLoadAppVersion(t *testing.T) {
	dir := t.TempDir()
	write := func(name, body string) string {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		return path
	}
	cases := []struct {
		name, body    string
		latest, least int
	}{
		{"ok", "# комментарий\nversionCode = 47\nversionName=1.0.0\nminVersionCode=45\n", 47, 45},
		{"no-min", "versionCode=47\n", 47, 0},
		{"no-code", "versionName=1.0.0\n", 0, 0},
		{"garbage", "versionCode=abc\nminVersionCode=x\n", 0, 0},
		{"commented", "#versionCode=47\n", 0, 0},
	}
	for _, c := range cases {
		got := LoadAppVersion(write(c.name, c.body))
		if got.VersionCode != c.latest || got.MinVersionCode != c.least {
			t.Errorf("%s: got %d/%d, want %d/%d", c.name, got.VersionCode, got.MinVersionCode, c.latest, c.least)
		}
	}
	if got := LoadAppVersion(filepath.Join(dir, "missing")); got.VersionCode != 0 || got.MinVersionCode != 0 {
		t.Errorf("нет файла: got %+v", got)
	}
	// настоящий файл репозитория читается с того же относительного пути, что и на сервере
	real := LoadAppVersion(filepath.Join("..", "..", AppVersionFile))
	if real.VersionCode <= 0 || real.MinVersionCode <= 0 || real.MinVersionCode > real.VersionCode {
		t.Errorf("app-version.properties в корне репозитория: versionCode = %d, minVersionCode = %d", real.VersionCode, real.MinVersionCode)
	}
}
