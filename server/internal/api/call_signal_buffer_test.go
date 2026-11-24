package api

import (
	"testing"
	"time"
)

func TestCallSignalBufferKeepsOrderAndExpires(t *testing.T) {
	buf := NewCallSignalBuffer(50 * time.Millisecond)
	buf.Add("caller", []byte("answer"))
	buf.Add("caller", []byte("ice"))
	frames := buf.Take("caller")
	if len(frames) != 2 || string(frames[0]) != "answer" || string(frames[1]) != "ice" {
		t.Fatalf("кадры: %q", frames)
	}
	if buf.Take("caller") != nil {
		t.Fatal("после Take буфер должен быть пуст")
	}

	buf.Add("caller", []byte("late"))
	time.Sleep(120 * time.Millisecond)
	if buf.Take("caller") != nil {
		t.Fatal("кадр должен истечь по сроку")
	}
}

func TestCallSignalBufferNewFrameExtendsTTL(t *testing.T) {
	buf := NewCallSignalBuffer(80 * time.Millisecond)
	buf.Add("caller", []byte("a"))
	time.Sleep(50 * time.Millisecond)
	buf.Add("caller", []byte("b"))
	time.Sleep(50 * time.Millisecond)
	if frames := buf.Take("caller"); len(frames) != 2 {
		t.Fatalf("срок должен продлеваться новым кадром, получили %q", frames)
	}
}
