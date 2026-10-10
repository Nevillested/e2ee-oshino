package api

import "testing"

// "В сети" — только пока приложение на экране: подключение само по себе
// (пуш разбудил, фоновая доставка) не делает онлайн, а "был(а) в сети"
// фиксируется, только когда пропадает соединение приложения, которое было
// на экране.
func TestPresenceOnlyWhileOnScreen(t *testing.T) {
	reg := NewConnectionRegistry()
	var left []string
	reg.SetLeftScreenHook(func(deviceID string) { left = append(left, deviceID) })

	reg.Add("bg", nil)
	if reg.IsOnline("bg") {
		t.Fatal("подключение без экрана — уже онлайн")
	}
	if _, ok := reg.Get("bg"); !ok {
		t.Fatal("фоновое соединение должно оставаться доступным для доставки")
	}
	reg.RemoveIfCurrent("bg", nil)
	if len(left) != 0 {
		t.Fatalf("фоновое соединение пропало — время \"был(а) в сети\" трогать нельзя: %v", left)
	}

	reg.Add("fg", nil)
	if online, changed := reg.SetForeground("fg", true); !online || !changed {
		t.Fatalf("приложение на экране: online=%v changed=%v", online, changed)
	}
	if !reg.IsOnline("fg") {
		t.Fatal("приложение на экране — не онлайн")
	}
	reg.RemoveIfCurrent("fg", nil)
	if len(left) != 1 || left[0] != "fg" {
		t.Fatalf("соединение приложения на экране пропало — нужен \"был(а) в сети\": %v", left)
	}
}
