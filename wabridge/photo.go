package main

import (
	"bytes"
	"encoding/binary"
	"image"
	_ "image/gif"
	"image/jpeg"
	_ "image/png"

	"golang.org/x/image/draw"
)

// preparePhoto turns an upload into what WhatsApp expects: an upright JPEG no larger than
// 1600px on its long side, plus a small thumbnail for the chat preview.
func preparePhoto(raw []byte) (full, thumb []byte, w, h int, err error) {
	img, _, err := decodeUpright(raw)
	if err != nil {
		return nil, nil, 0, 0, err
	}
	img = fit(img, 1600)
	var a, b bytes.Buffer
	if err = jpeg.Encode(&a, img, &jpeg.Options{Quality: 82}); err != nil {
		return
	}
	jpeg.Encode(&b, fit(img, 100), &jpeg.Options{Quality: 60})
	return a.Bytes(), b.Bytes(), img.Bounds().Dx(), img.Bounds().Dy(), nil
}

func decodeUpright(raw []byte) (image.Image, string, error) {
	img, format, err := image.Decode(bytes.NewReader(raw))
	if err != nil {
		return nil, "", err
	}
	return upright(img, exifOrientation(raw)), format, nil
}

func fit(img image.Image, max int) image.Image {
	w, h := img.Bounds().Dx(), img.Bounds().Dy()
	if w <= max && h <= max {
		return img
	}
	if w >= h {
		h, w = h*max/w, max
	} else {
		w, h = w*max/h, max
	}
	dst := image.NewRGBA(image.Rect(0, 0, w, h))
	draw.CatmullRom.Scale(dst, dst.Bounds(), img, img.Bounds(), draw.Src, nil)
	return dst
}

// iPhone cameras store photos sideways plus an EXIF "orientation" tag; re-encoding drops the
// tag, so apply it to the pixels. Handles the values cameras actually write (1, 3, 6, 8).
func upright(img image.Image, o int) image.Image {
	if o != 3 && o != 6 && o != 8 {
		return img
	}
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	var dst *image.RGBA
	if o == 3 {
		dst = image.NewRGBA(image.Rect(0, 0, w, h))
	} else {
		dst = image.NewRGBA(image.Rect(0, 0, h, w))
	}
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			c := img.At(b.Min.X+x, b.Min.Y+y)
			switch o {
			case 3:
				dst.Set(w-1-x, h-1-y, c)
			case 6: // rotate 90 clockwise
				dst.Set(h-1-y, x, c)
			case 8: // rotate 90 counter-clockwise
				dst.Set(y, w-1-x, c)
			}
		}
	}
	return dst
}

// exifOrientation reads tag 0x0112 from a JPEG's APP1/Exif block. 1 (normal) if absent.
func exifOrientation(b []byte) int {
	if len(b) < 4 || b[0] != 0xFF || b[1] != 0xD8 {
		return 1
	}
	for i := 2; i+4 <= len(b); {
		if b[i] != 0xFF {
			return 1
		}
		marker, size := b[i+1], int(binary.BigEndian.Uint16(b[i+2:]))
		if marker == 0xDA || i+2+size > len(b) { // start of image data: no more metadata
			return 1
		}
		seg := b[i+4 : i+2+size]
		if marker == 0xE1 && len(seg) > 14 && string(seg[:6]) == "Exif\x00\x00" {
			t := seg[6:]
			var bo binary.ByteOrder = binary.BigEndian
			if string(t[:2]) == "II" {
				bo = binary.LittleEndian
			}
			ifd := int(bo.Uint32(t[4:]))
			if ifd+2 > len(t) {
				return 1
			}
			n := int(bo.Uint16(t[ifd:]))
			for e := 0; e < n; e++ {
				p := ifd + 2 + e*12
				if p+12 > len(t) {
					break
				}
				if bo.Uint16(t[p:]) == 0x0112 {
					return int(bo.Uint16(t[p+8:]))
				}
			}
			return 1
		}
		i += 2 + size
	}
	return 1
}
