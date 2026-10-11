package api

import (
	"archive/zip"
	"bytes"
	"compress/gzip"
	"encoding/json"
	"image"
	_ "image/png" // DecodeConfig для PNG
	"io"
	"path"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	_ "golang.org/x/image/webp" // DecodeConfig для WebP
)

// Ограничения стикерпаков (решение владельца 2026-10-11).
const (
	maxStickersPerPack  = 120
	maxOwnStickerPacks  = 10
	maxStaticStickerSz  = 512 * 1024 // PNG/WebP
	maxTgsStickerSz     = 64 * 1024  // TGS — сжатый Lottie
	maxTgsJSONSz        = 1024 * 1024
	maxStickerSide      = 512
	maxStickerArchiveSz = 80 * 1024 * 1024
	maxPackTitleRunes   = 20
)

// Название пака: латиница, кириллица, цифры и пробелы, 1–20 символов.
var packTitleRe = regexp.MustCompile(`^[A-Za-zА-Яа-яЁё0-9 ]+$`)

// validPackTitle — название уже без пробелов по краям.
func validPackTitle(title string) bool {
	n := utf8.RuneCountInString(title)
	return n >= 1 && n <= maxPackTitleRunes && packTitleRe.MatchString(title) && strings.TrimSpace(title) == title
}

// stickerCheckError — что не так с архивом или файлом; Code — ключ для
// сообщения на клиенте, Name — файл в архиве, Limit — нарушенный предел.
type stickerCheckError struct {
	Code  string
	Name  string
	Limit int
}

func (e *stickerCheckError) Error() string { return e.Code + " " + e.Name }

// archiveEntry — файл-кандидат в стикеры из архива.
type archiveEntry struct {
	file *zip.File
	name string // путь внутри архива
}

// stickerEntries — файлы архива в порядке стикеров: служебное (папки,
// __MACOSX, скрытые файлы) пропускается, остальное — по имени с учётом
// чисел (2 раньше 10).
func stickerEntries(r *zip.Reader) []archiveEntry {
	var out []archiveEntry
	for _, f := range r.File {
		if f.FileInfo().IsDir() {
			continue
		}
		name := f.Name
		base := path.Base(name)
		if strings.HasPrefix(name, "__MACOSX/") || strings.HasPrefix(base, ".") || strings.EqualFold(base, "Thumbs.db") {
			continue
		}
		out = append(out, archiveEntry{file: f, name: name})
	}
	sort.SliceStable(out, func(i, j int) bool { return naturalLess(out[i].name, out[j].name) })
	return out
}

// naturalLess — сравнение строк, где группы цифр сравниваются как числа.
func naturalLess(a, b string) bool {
	for a != "" && b != "" {
		ca, cb := a[0], b[0]
		if isDigit(ca) && isDigit(cb) {
			na, ra := leadingNumber(a)
			nb, rb := leadingNumber(b)
			if na != nb {
				return na < nb
			}
			a, b = ra, rb
			continue
		}
		la, lb := unicode.ToLower(rune(ca)), unicode.ToLower(rune(cb))
		if la != lb {
			return la < lb
		}
		a, b = a[1:], b[1:]
	}
	return len(a) < len(b)
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

func leadingNumber(s string) (int, string) {
	i := 0
	for i < len(s) && isDigit(s[i]) {
		i++
	}
	n, _ := strconv.Atoi(s[:min(i, 9)])
	return n, s[i:]
}

// inspectSticker — тип, объём и размеры одного файла; формат — png, webp или tgs.
func inspectSticker(name string, data []byte) (string, *stickerCheckError) {
	ext := strings.ToLower(path.Ext(name))
	if ext == ".webm" {
		return "", &stickerCheckError{Code: "file.webm", Name: name}
	}
	switch {
	case bytes.HasPrefix(data, []byte("\x89PNG\r\n\x1a\n")):
		return checkStaticSticker("png", name, data)
	case len(data) >= 12 && bytes.Equal(data[0:4], []byte("RIFF")) && bytes.Equal(data[8:12], []byte("WEBP")):
		return checkStaticSticker("webp", name, data)
	case len(data) >= 2 && data[0] == 0x1f && data[1] == 0x8b:
		return checkTgsSticker(name, data)
	}
	return "", &stickerCheckError{Code: "file.unsupported", Name: name}
}

func checkStaticSticker(format, name string, data []byte) (string, *stickerCheckError) {
	if len(data) > maxStaticStickerSz {
		return "", &stickerCheckError{Code: "file.tooLarge", Name: name, Limit: maxStaticStickerSz / 1024}
	}
	cfg, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return "", &stickerCheckError{Code: "file.corrupt", Name: name}
	}
	if cfg.Width <= 0 || cfg.Height <= 0 || cfg.Width > maxStickerSide || cfg.Height > maxStickerSide {
		return "", &stickerCheckError{Code: "file.badDimensions", Name: name, Limit: maxStickerSide}
	}
	return format, nil
}

// checkTgsSticker — TGS: gzip с Lottie JSON внутри (слои и размеры кадра).
func checkTgsSticker(name string, data []byte) (string, *stickerCheckError) {
	if len(data) > maxTgsStickerSz {
		return "", &stickerCheckError{Code: "file.tooLarge", Name: name, Limit: maxTgsStickerSz / 1024}
	}
	zr, err := gzip.NewReader(bytes.NewReader(data))
	if err != nil {
		return "", &stickerCheckError{Code: "file.corrupt", Name: name}
	}
	raw, err := io.ReadAll(io.LimitReader(zr, maxTgsJSONSz+1))
	if err != nil || len(raw) > maxTgsJSONSz {
		return "", &stickerCheckError{Code: "file.corrupt", Name: name}
	}
	var lottie struct {
		W      int               `json:"w"`
		H      int               `json:"h"`
		Layers []json.RawMessage `json:"layers"`
	}
	if json.Unmarshal(raw, &lottie) != nil || len(lottie.Layers) == 0 {
		return "", &stickerCheckError{Code: "file.corrupt", Name: name}
	}
	if lottie.W <= 0 || lottie.H <= 0 || lottie.W > maxStickerSide || lottie.H > maxStickerSide {
		return "", &stickerCheckError{Code: "file.badDimensions", Name: name, Limit: maxStickerSide}
	}
	return "tgs", nil
}

// readArchiveEntry — содержимое файла архива с защитой от "zip-бомбы":
// больше [limit] не читаем.
func readArchiveEntry(e archiveEntry, limit int) ([]byte, *stickerCheckError) {
	if e.file.UncompressedSize64 > uint64(limit) {
		return nil, &stickerCheckError{Code: "file.tooLarge", Name: e.name, Limit: limit / 1024}
	}
	rc, err := e.file.Open()
	if err != nil {
		return nil, &stickerCheckError{Code: "file.corrupt", Name: e.name}
	}
	defer rc.Close()
	data, err := io.ReadAll(io.LimitReader(rc, int64(limit)+1))
	if err != nil {
		return nil, &stickerCheckError{Code: "file.corrupt", Name: e.name}
	}
	if len(data) > limit {
		return nil, &stickerCheckError{Code: "file.tooLarge", Name: e.name, Limit: limit / 1024}
	}
	return data, nil
}

// stickerContentType — Content-Type файла стикера по формату.
func stickerContentType(format string) string {
	switch format {
	case "png":
		return "image/png"
	case "webp":
		return "image/webp"
	default:
		return "application/x-tgsticker"
	}
}
