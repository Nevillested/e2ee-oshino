package api

import (
	"net/http"
	"server/internal/db"
)

func NewSessionCheckHandler(queries *db.Queries) func(http.ResponseWriter, *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		var _, err = CheckToken(w, r, queries)
		if err != nil {
			return
		}
		w.WriteHeader(http.StatusOK)
	}
}
