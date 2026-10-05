package native_update

import "core:crypto/sha2"
import "core:encoding/json"
import "core:os"
import "core:strings"

MAX_ARCHIVE_BYTES :: 256 * 1024 * 1024
MAX_MANIFEST_BYTES :: 16 * 1024
READ_BUFFER_BYTES :: 256 * 1024

// Config identifies one application's update feed and the identity a downloaded
// bundle must carry. feed_url is the HTTPS address of the manifest; the archive
// is fetched from the same directory. bundle_name is the file name of what the
// archive holds and what is installed: "<Name>.app", or a bare executable whose
// Info.plist is embedded in its __TEXT,__info_plist section.
Config :: struct {
	feed_url:    string,
	bundle_id:   string,
	team_id:     string,
	bundle_name: string,
}

File :: struct {
	name:   string,
	bytes:  i64,
	sha256: string,
}

Manifest :: struct {
	schema:    int,
	bundle_id: string,
	version:   string,
	archive:   File,
}

Status :: enum u8 {
	Idle,
	Checking,
	Up_To_Date,
	Ready,
	Error,
}

Prepared :: struct {
	status:   Status,
	manifest: Manifest,
	root:     string,
	app_path: string,
	error:    string,
}

Version :: [3]int

version_parse :: proc(text: string) -> (Version, bool) {
	version: Version
	rest := text
	for index in 0 ..< 3 {
		end := 0
		for end < len(rest) && rest[end] >= '0' && rest[end] <= '9' {end += 1}
		if end == 0 || end > 9 || (end > 1 && rest[0] == '0') {return {}, false}
		for character in rest[:end] {version[index] = version[index]*10+int(character-'0')}
		rest = rest[end:]
		if index < 2 {
			if len(rest) == 0 || rest[0] != '.' {return {}, false}
			rest = rest[1:]
		}
	}
	return version, len(rest) == 0
}

version_newer :: proc(candidate, current: string) -> bool {
	a, a_ok := version_parse(candidate)
	b, b_ok := version_parse(current)
	if !a_ok || !b_ok {return false}
	for index in 0 ..< 3 {
		if a[index] != b[index] {return a[index] > b[index]}
	}
	return false
}

hex_decode :: proc(text: string, output: []u8) -> bool {
	if len(text) != 2*len(output) {return false}
	nibble :: proc(character: u8) -> (u8, bool) {
		switch character {
		case '0' ..= '9': return character-'0', true
		case 'a' ..= 'f': return character-'a'+10, true
		}
		return 0, false
	}
	for &byte, index in output {
		high, high_ok := nibble(text[2*index])
		low, low_ok := nibble(text[2*index+1])
		if !high_ok || !low_ok {return false}
		byte = high << 4 | low
	}
	return true
}

// identifier_valid admits what bundle IDs, team IDs and archive names are made of,
// so none of them can alter a code requirement or a path.
identifier_valid :: proc(text: string, extra: string) -> bool {
	if len(text) == 0 || len(text) > 160 || strings.contains(text, "..") {return false}
	for character in text {
		switch {
		case character >= 'a' && character <= 'z', character >= 'A' && character <= 'Z', character >= '0' && character <= '9':
		case character == '.', character == '-':
		case strings.contains_rune(extra, character):
		case:
			return false
		}
	}
	return true
}

archive_valid :: proc(file: File) -> bool {
	hash: [32]u8
	return file.bytes > 0 && file.bytes <= MAX_ARCHIVE_BYTES && hex_decode(file.sha256, hash[:]) &&
		identifier_valid(file.name, "_") && strings.has_suffix(file.name, ".zip")
}

manifest_decode :: proc(data: []u8, bundle_id: string, allocator := context.allocator) -> (Manifest, bool) {
	if len(data) == 0 || len(data) > MAX_MANIFEST_BYTES {return {}, false}
	manifest: Manifest
	if json.unmarshal(data, &manifest, allocator = allocator) != nil {return {}, false}
	_, version_ok := version_parse(manifest.version)
	if manifest.schema != 1 || manifest.bundle_id != bundle_id || !version_ok || !archive_valid(manifest.archive) {return {}, false}
	return manifest, true
}

// file_verify checks a downloaded file's size and SHA-256 against the manifest.
file_verify :: proc(path: string, file: File) -> bool {
	expected: [32]u8
	if !hex_decode(file.sha256, expected[:]) {return false}
	handle, open_error := os.open(path)
	if open_error != nil {return false}
	defer os.close(handle)
	size, size_error := os.file_size(handle)
	if size_error != nil || size != file.bytes {return false}
	context_256: sha2.Context_256
	sha2.init_256(&context_256)
	buffer: [READ_BUFFER_BYTES]u8
	remaining := size
	for remaining > 0 {
		count, read_error := os.read(handle, buffer[:min(remaining, i64(len(buffer)))])
		if count <= 0 || (read_error != nil && read_error != .EOF) {return false}
		sha2.update(&context_256, buffer[:count])
		remaining -= i64(count)
	}
	actual: [32]u8
	sha2.final(&context_256, actual[:])
	difference: u8
	for index in 0 ..< len(actual) {difference |= actual[index] ~ expected[index]}
	return difference == 0
}
