package api

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestRequireAppVersion(t *testing.T) {
	ok := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })
	gate := RequireAppVersion(AppVersion{VersionCode: 45, ApkURL: "https://example/app.apk"}, ok)

	cases := []struct {
		path, version string
		want          int
	}{
		{"/chats/muted", "45", http.StatusOK},
		{"/chats/muted", "44", http.StatusUpgradeRequired},
		{"/chats/muted", "46", http.StatusUpgradeRequired},
		{"/ws", "", http.StatusUpgradeRequired},
		{"/app/version", "", http.StatusOK},
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

	off := RequireAppVersion(AppVersion{}, ok)
	rec := httptest.NewRecorder()
	off.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/chats/muted", nil))
	if rec.Code != http.StatusOK {
		t.Errorf("проверка выключена (0), а запрос отклонён: %d", rec.Code)
	}
}
