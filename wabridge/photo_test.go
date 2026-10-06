package main

import (
	"bytes"
	"image"
	"image/color"
	"image/jpeg"
	"testing"
)

// jpegWithOrientation: a 40x20 JPEG (red left half) carrying an EXIF orientation tag.
func jpegWithOrientation(t *testing.T, o byte) []byte {
	img := image.NewRGBA(image.Rect(0, 0, 40, 20))
	for y := 0; y < 20; y++ {
		for x := 0; x < 40; x++ {
			c := color.RGBA{0, 0, 255, 255}
			if x < 20 {
				c = color.RGBA{255, 0, 0, 255}
			}
			img.Set(x, y, c)
		}
	}
	var b bytes.Buffer
	if err := jpeg.Encode(&b, img, nil); err != nil {
		t.Fatal(err)
	}
	tiff := []byte{'M', 'M', 0, 42, 0, 0, 0, 8, 0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, o, 0, 0, 0, 0, 0, 0}
	app1 := append([]byte("Exif\x00\x00"), tiff...)
	seg := append([]byte{0xFF, 0xE1, byte((len(app1) + 2) >> 8), byte(len(app1) + 2)}, app1...)
	raw := b.Bytes()
	return append(append(append([]byte{}, raw[:2]...), seg...), raw[2:]...)
}

func TestPreparePhotoOrientation(t *testing.T) {
	for _, tc := range []struct {
		o    byte
		w, h int
	}{
		{1, 40, 20}, // as is: red stays left
		{6, 20, 40}, // 90 clockwise: red goes to the top
		{8, 20, 40}, // 90 counter-clockwise: red goes to the bottom
		{3, 40, 20}, // 180: red goes right
	} {
		raw := jpegWithOrientation(t, tc.o)
		if got := exifOrientation(raw); got != int(tc.o) {
			t.Fatalf("orientation %d read as %d", tc.o, got)
		}
		full, thumb, w, h, err := preparePhoto(raw)
		if err != nil || len(thumb) == 0 {
			t.Fatalf("o=%d: %v", tc.o, err)
		}
		if w != tc.w || h != tc.h {
			t.Fatalf("o=%d: got %dx%d want %dx%d", tc.o, w, h, tc.w, tc.h)
		}
		img, _ := jpeg.Decode(bytes.NewReader(full))
		r, _, _, _ := img.At(2, 2).RGBA() // top-left pixel is red only for 1 and 6
		redTopLeft := r > 0x8000
		if want := (tc.o == 1) || (tc.o == 6); redTopLeft != want {
			t.Fatalf("o=%d: top-left red=%v want %v", tc.o, redTopLeft, want)
		}
	}
}
