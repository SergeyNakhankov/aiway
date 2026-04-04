SHELL := /bin/bash
VERSION := $(shell cat VERSION)
BUILD_DIR := out
GOTOOLCHAIN ?= go1.25.4
ARCHES := aarch64-3.10 armv7-3.2 x64-3.2 mips-3.4 mipsel-3.4
LDFLAGS := -s -w -X github.com/kirniy/aiway/router/manager/internal/app.Version=$(VERSION)

.PHONY: frontend build test package clean

frontend:
	npm --prefix web ci
	npm --prefix web run build
	rm -rf webui/dist
	mkdir -p webui/dist
	cp -R web/dist/. webui/dist/

build: frontend
	mkdir -p $(BUILD_DIR)
	GOTOOLCHAIN=$(GOTOOLCHAIN) CGO_ENABLED=0 GOOS=linux GOARCH=arm64 GOARM64=v8.0 go build -trimpath -ldflags '$(LDFLAGS)' -o $(BUILD_DIR)/aiway-manager_aarch64-3.10-kn ./cmd/aiway-manager
	GOTOOLCHAIN=$(GOTOOLCHAIN) CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=5 go build -trimpath -ldflags '$(LDFLAGS)' -o $(BUILD_DIR)/aiway-manager_armv7-3.2-kn ./cmd/aiway-manager
	GOTOOLCHAIN=$(GOTOOLCHAIN) CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOAMD64=v1 go build -trimpath -ldflags '$(LDFLAGS)' -o $(BUILD_DIR)/aiway-manager_x64-3.2-kn ./cmd/aiway-manager
	GOTOOLCHAIN=$(GOTOOLCHAIN) CGO_ENABLED=0 GOOS=linux GOARCH=mips GOMIPS=softfloat go build -trimpath -ldflags '$(LDFLAGS)' -o $(BUILD_DIR)/aiway-manager_mips-3.4-kn ./cmd/aiway-manager
	GOTOOLCHAIN=$(GOTOOLCHAIN) CGO_ENABLED=0 GOOS=linux GOARCH=mipsle GOMIPS=softfloat go build -trimpath -ldflags '$(LDFLAGS)' -o $(BUILD_DIR)/aiway-manager_mipsel-3.4-kn ./cmd/aiway-manager

test:
	GOTOOLCHAIN=$(GOTOOLCHAIN) go test ./cmd/... ./internal/... ./webui

package: build
	@for arch in $(ARCHES); do \
		rm -rf $(BUILD_DIR)/pkg-$$arch; \
		mkdir -p $(BUILD_DIR)/pkg-$$arch/control $(BUILD_DIR)/pkg-$$arch/data/opt/bin $(BUILD_DIR)/pkg-$$arch/data/opt/etc/init.d; \
		echo "Package: aiway-manager" > $(BUILD_DIR)/pkg-$$arch/control/control; \
		echo "Version: $(VERSION)" >> $(BUILD_DIR)/pkg-$$arch/control/control; \
		echo "Architecture: $${arch}_kn" >> $(BUILD_DIR)/pkg-$$arch/control/control; \
		echo "Section: net" >> $(BUILD_DIR)/pkg-$$arch/control/control; \
		echo "Maintainer: kirniy" >> $(BUILD_DIR)/pkg-$$arch/control/control; \
		echo "Description: AIWAY Keenetic dashboard and LAN API" >> $(BUILD_DIR)/pkg-$$arch/control/control; \
		cp package/postinst $(BUILD_DIR)/pkg-$$arch/control/postinst; \
		cp package/prerm $(BUILD_DIR)/pkg-$$arch/control/prerm; \
		chmod +x $(BUILD_DIR)/pkg-$$arch/control/postinst $(BUILD_DIR)/pkg-$$arch/control/prerm; \
		cp $(BUILD_DIR)/aiway-manager_$${arch}-kn $(BUILD_DIR)/pkg-$$arch/data/opt/bin/aiway-manager; \
		cp package/S99aiway-manager $(BUILD_DIR)/pkg-$$arch/data/opt/etc/init.d/S99aiway-manager; \
		chmod +x $(BUILD_DIR)/pkg-$$arch/data/opt/bin/aiway-manager $(BUILD_DIR)/pkg-$$arch/data/opt/etc/init.d/S99aiway-manager; \
		printf '2.0' > $(BUILD_DIR)/pkg-$$arch/debian-binary; \
		( cd $(BUILD_DIR)/pkg-$$arch/control && tar -czf ../control.tar.gz . ); \
		( cd $(BUILD_DIR)/pkg-$$arch/data && tar -czf ../data.tar.gz . ); \
		( cd $(BUILD_DIR)/pkg-$$arch && tar -czf ../aiway-manager_$(VERSION)_$${arch}-kn.ipk control.tar.gz data.tar.gz debian-binary ); \
	done

clean:
	rm -rf $(BUILD_DIR) web/dist webui/dist
