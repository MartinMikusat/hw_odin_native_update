package native_update

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

TEST_BUNDLE :: "com.example.app"
TEST_HASH :: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

manifest_text :: proc(version, name, bundle, hash: string, bytes: int) -> string {
	return strings.concatenate({
		`{"schema":1,"bundle_id":"`, bundle, `","version":"`, version, `","archive":{"name":"`, name,
		`","bytes":`, fmt.tprintf("%d", bytes), `,"sha256":"`, hash, `"}}`,
	}, context.temp_allocator)
}

@(test)
versions_parse_strictly_and_compare_numerically :: proc(t: ^testing.T) {
	testing.expect(t, version_newer("0.10.0", "0.9.9"))
	testing.expect(t, version_newer("1.0.0", "0.99.99"))
	testing.expect(t, !version_newer("1.2.3", "1.2.3"))
	testing.expect(t, !version_newer("1.2.2", "1.2.3"))
	for bad in ([]string{"", "1.2", "1.2.3.4", "01.2.3", "1.2.x", "1.2.3-beta", "1234567890.0.0"}) {
		_, ok := version_parse(bad)
		testing.expect(t, !ok, bad)
	}
}

@(test)
manifest_rejects_anything_but_a_well_formed_archive_for_this_bundle :: proc(t: ^testing.T) {
	good := manifest_text("1.2.3", "app-1.2.3.zip", TEST_BUNDLE, TEST_HASH, 100)
	manifest, ok := manifest_decode(transmute([]u8)good, TEST_BUNDLE, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, manifest.version, "1.2.3")
	testing.expect_value(t, manifest.archive.name, "app-1.2.3.zip")

	cases := []string{
		manifest_text("1.2.3", "app-1.2.3.zip", "com.other.app", TEST_HASH, 100),
		manifest_text("1.2", "app-1.2.3.zip", TEST_BUNDLE, TEST_HASH, 100),
		manifest_text("1.2.3", "../app.zip", TEST_BUNDLE, TEST_HASH, 100),
		manifest_text("1.2.3", "dir/app.zip", TEST_BUNDLE, TEST_HASH, 100),
		manifest_text("1.2.3", "app.dmg", TEST_BUNDLE, TEST_HASH, 100),
		manifest_text("1.2.3", "app.zip", TEST_BUNDLE, "abcd", 100),
		manifest_text("1.2.3", "app.zip", TEST_BUNDLE, TEST_HASH, 0),
		manifest_text("1.2.3", "app.zip", TEST_BUNDLE, TEST_HASH, MAX_ARCHIVE_BYTES+1),
		`{"schema":2,"bundle_id":"com.example.app","version":"1.2.3","archive":{}}`,
		"not json",
		"",
	}
	for text in cases {
		_, accepted := manifest_decode(transmute([]u8)text, TEST_BUNDLE, context.temp_allocator)
		testing.expect(t, !accepted, text)
	}
}

@(test)
file_verify_checks_size_and_hash :: proc(t: ^testing.T) {
	path := "/tmp/hw_odin_native_update-test.bin"
	testing.expect(t, os.write_entire_file(path, "") == nil)
	defer os.remove(path)
	empty := File{name = "a.zip", bytes = 0, sha256 = TEST_HASH}
	testing.expect(t, file_verify(path, empty))
	testing.expect(t, !file_verify(path, File{bytes = 1, sha256 = TEST_HASH}))
	testing.expect(t, !file_verify(path, File{bytes = 0, sha256 = "00e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b8"}))
	testing.expect(t, !file_verify("/tmp/hw_odin_native_update-missing.bin", empty))
}

@(test)
requirement_pins_team_identifier_and_version_and_refuses_injection :: proc(t: ^testing.T) {
	config := Config{bundle_id = TEST_BUNDLE, team_id = "ABCDE12345"}
	text, ok := requirement(config, "1.2.3")
	testing.expect(t, ok)
	testing.expect(t, strings.contains(text, `certificate leaf[subject.OU] = "ABCDE12345"`))
	testing.expect(t, strings.contains(text, `identifier "com.example.app"`))
	testing.expect(t, strings.contains(text, `info[CFBundleShortVersionString] = "1.2.3"`))
	_, ok = requirement(config, `1.2.3" or anchor apple`)
	testing.expect(t, !ok)
	_, ok = requirement(Config{bundle_id = `x" or true or identifier "y`, team_id = "ABCDE12345"}, "1.2.3")
	testing.expect(t, !ok)
	_, ok = requirement(Config{bundle_id = TEST_BUNDLE, team_id = `T" or true`}, "1.2.3")
	testing.expect(t, !ok)
}

@(test)
feed_directory_requires_https :: proc(t: ^testing.T) {
	directory, ok := feed_directory("https://github.com/o/r/releases/latest/download/update.json")
	testing.expect(t, ok)
	testing.expect_value(t, directory, "https://github.com/o/r/releases/latest/download")
	_, ok = feed_directory("http://github.com/o/r/update.json")
	testing.expect(t, !ok)
	_, ok = feed_directory("https://update.json")
	testing.expect(t, !ok)
}
