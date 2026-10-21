VERSION := $(shell node -p "require('./webos-meta/appinfo.json').version")

pack:
	npm run ipk

install:
	ares-install --device lg-tv ./build/com.aprogsys.immuch360_$(VERSION)_all.ipk

launch:
	ares-launch --device lg-tv com.aprogsys.immuch360

inspect:
	ares-inspect --device lg-tv com.aprogsys.immuch360
