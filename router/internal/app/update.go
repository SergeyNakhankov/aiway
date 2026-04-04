package app

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"time"
)

type Updater struct {
	repo string
}

func NewUpdater() Updater {
	return Updater{repo: "kirniy/aiway"}
}

func (u Updater) Check() (UpdateInfo, error) {
	candidates, err := detectKeeneticArchCandidates()
	if err != nil {
		return UpdateInfo{}, err
	}

	req, err := http.NewRequest(http.MethodGet, fmt.Sprintf("https://api.github.com/repos/%s/releases?per_page=20", u.repo), nil)
	if err != nil {
		return UpdateInfo{}, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "aiway-manager/"+Version)

	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return UpdateInfo{}, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return UpdateInfo{}, err
	}
	if resp.StatusCode >= 400 {
		return UpdateInfo{}, fmt.Errorf("github releases responded with http %d", resp.StatusCode)
	}

	var releases []githubRelease
	if err := json.Unmarshal(body, &releases); err != nil {
		return UpdateInfo{}, err
	}

	if info, ok := findReleaseAsset(releases, candidates); ok {
		info.Current = Version
		info.Available = info.Latest != Version
		return info, nil
	}

	return UpdateInfo{}, fmt.Errorf(
		"no router package found for %s; supported package architectures: %s",
		strings.Join(candidates, ", "),
		strings.Join(supportedKeeneticArchitectures, ", "),
	)
}

func (u Updater) Apply() (UpdateInfo, error) {
	info, err := u.Check()
	if err != nil {
		return info, err
	}
	if !info.Available {
		return info, nil
	}

	cmd := exec.Command("/bin/sh", "-c", fmt.Sprintf(`set -e
mkdir -p /opt/tmp
tmp="/opt/tmp/%s"
cleanup() { rm -f "$tmp"; }
trap cleanup EXIT
if command -v curl >/dev/null 2>&1; then
  curl -fsSL -o "$tmp" "%s"
else
  wget -qO "$tmp" "%s"
fi
opkg install "$tmp"
`, info.Package, info.URL, info.URL))
	out, err := cmd.CombinedOutput()
	if err != nil {
		return info, fmt.Errorf("update failed: %v: %s", err, strings.TrimSpace(string(out)))
	}
	return info, nil
}

type githubRelease struct {
	TagName    string         `json:"tag_name"`
	Draft      bool           `json:"draft"`
	Prerelease bool           `json:"prerelease"`
	Assets     []releaseAsset `json:"assets"`
}

type releaseAsset struct {
	Name string `json:"name"`
	URL  string `json:"browser_download_url"`
}

var supportedKeeneticArchitectures = []string{
	"aarch64-3.10",
	"armv7-3.2",
	"x64-3.2",
	"mips-3.4",
	"mipsel-3.4",
}

func detectKeeneticArchCandidates() ([]string, error) {
	cmd := exec.Command("/bin/sh", "-c", `opkg print-architecture`)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("cannot detect architecture: %v", err)
	}

	candidates := parseKeeneticArchCandidates(string(out))
	if len(candidates) == 0 {
		return nil, fmt.Errorf(
			"no supported Keenetic architecture found in opkg print-architecture (got: %s)",
			strings.TrimSpace(string(out)),
		)
	}
	return candidates, nil
}

func parseKeeneticArchCandidates(output string) []string {
	type item struct {
		name     string
		priority int
	}

	var matches []item
	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parts := strings.Fields(line)
		if len(parts) < 3 || parts[0] != "arch" {
			continue
		}
		name := parts[1]
		if name == "all" || name == "noarch" {
			continue
		}
		priority, _ := strconv.Atoi(parts[2])
		if strings.Contains(name, "_kn") {
			priority += 1000
		}
		normalized := normalizeKeeneticArch(name)
		if normalized == "" {
			continue
		}
		matches = append(matches, item{name: normalized, priority: priority})
	}

	sort.Slice(matches, func(i, j int) bool { return matches[i].priority > matches[j].priority })

	candidates := make([]string, 0, len(matches))
	seen := map[string]struct{}{}
	for _, match := range matches {
		if _, ok := seen[match.name]; ok {
			continue
		}
		seen[match.name] = struct{}{}
		candidates = append(candidates, match.name)
	}
	return candidates
}

func normalizeKeeneticArch(name string) string {
	name = strings.ToLower(strings.TrimSpace(name))
	name = strings.TrimSuffix(name, "_kn")
	switch {
	case strings.HasPrefix(name, "aarch64-3.10"), strings.HasPrefix(name, "arm64-3.10"), name == "aarch64", name == "arm64":
		return "aarch64-3.10"
	case strings.HasPrefix(name, "armv7sf-3.2"), strings.HasPrefix(name, "armv7-3.2"), strings.HasPrefix(name, "armv7sf"), strings.HasPrefix(name, "armv7"):
		return "armv7-3.2"
	case strings.HasPrefix(name, "x64-3.2"), strings.HasPrefix(name, "x86_64-3.2"), strings.HasPrefix(name, "amd64-3.2"), strings.HasPrefix(name, "x64"), strings.HasPrefix(name, "x86_64"), strings.HasPrefix(name, "amd64"):
		return "x64-3.2"
	case strings.HasPrefix(name, "mipsel-3.4"), strings.HasPrefix(name, "mipselsf-3.4"), strings.HasPrefix(name, "mipsel"), strings.HasPrefix(name, "mipselsf"):
		return "mipsel-3.4"
	case strings.HasPrefix(name, "mips-3.4"), strings.HasPrefix(name, "mipssf-3.4"), strings.HasPrefix(name, "mipssf"), name == "mips":
		return "mips-3.4"
	default:
		return ""
	}
}

func findReleaseAsset(releases []githubRelease, candidates []string) (UpdateInfo, bool) {
	for _, release := range releases {
		if release.Draft || release.Prerelease {
			continue
		}
		latest := strings.TrimPrefix(strings.TrimSpace(release.TagName), "v")
		if latest == "" {
			continue
		}
		for _, candidate := range candidates {
			packageName := fmt.Sprintf("aiway-manager_%s_%s-kn.ipk", latest, candidate)
			for _, asset := range release.Assets {
				if asset.Name != packageName {
					continue
				}
				return UpdateInfo{
					Latest:  latest,
					Package: asset.Name,
					URL:     asset.URL,
				}, true
			}
		}
	}
	return UpdateInfo{}, false
}
