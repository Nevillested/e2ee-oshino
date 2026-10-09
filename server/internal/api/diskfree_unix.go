//go:build !windows

package api

import "syscall"

// diskFreeBytes — сколько байт на файловой системе с path доступно
// непривилегированному процессу (Bavail, не Bfree: место, зарезервированное
// под root, нам всё равно не достанется).
func diskFreeBytes(path string) (int64, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return 0, err
	}
	return int64(st.Bavail) * int64(st.Bsize), nil
}
