package app

import (
	"reflect"
	"testing"
)

func TestParseKeeneticArchCandidates(t *testing.T) {
	output := `
arch all 1
arch noarch 1
arch armv7sf-3.2 10
arch armv7sf-3.2_kn 200
arch mipselsf-3.4 150
`

	got := parseKeeneticArchCandidates(output)
	want := []string{"armv7-3.2", "mipsel-3.4"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("parseKeeneticArchCandidates() = %v, want %v", got, want)
	}
}

func TestNormalizeKeeneticArchAliases(t *testing.T) {
	cases := map[string]string{
		"aarch64-3.10_kn": "aarch64-3.10",
		"arm64-3.10_kn":   "aarch64-3.10",
		"armv7sf-3.2_kn":  "armv7-3.2",
		"x86_64-3.2_kn":   "x64-3.2",
		"mipselsf-3.4_kn": "mipsel-3.4",
		"mipssf-3.4_kn":   "mips-3.4",
	}

	for input, want := range cases {
		if got := normalizeKeeneticArch(input); got != want {
			t.Fatalf("normalizeKeeneticArch(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestFindReleaseAssetSkipsAssetlessLatestRelease(t *testing.T) {
	releases := []githubRelease{
		{TagName: "v1.0.0"},
		{
			TagName: "v0.1.4",
			Assets: []releaseAsset{
				{
					Name: "aiway-manager_0.1.4_aarch64-3.10-kn.ipk",
					URL:  "https://example.test/aiway-manager_0.1.4_aarch64-3.10-kn.ipk",
				},
			},
		},
	}

	info, ok := findReleaseAsset(releases, []string{"aarch64-3.10"})
	if !ok {
		t.Fatal("findReleaseAsset() did not find a compatible asset")
	}
	if info.Latest != "0.1.4" {
		t.Fatalf("findReleaseAsset().Latest = %q, want %q", info.Latest, "0.1.4")
	}
	if info.Package != "aiway-manager_0.1.4_aarch64-3.10-kn.ipk" {
		t.Fatalf("findReleaseAsset().Package = %q", info.Package)
	}
}
