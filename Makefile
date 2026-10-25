# make robot          build, then run the robot user over every scenario: build/robot/report.html
# make robot ONLY=toggles,write-zoom1
# make robot-old C=<commit> ONLY=...   the same robot against an old commit (robot/old-commit.sh)
.PHONY: build robot robot-tools robot-old test

build:
	./build.sh

robot-tools:
	@mkdir -p build
	swiftc -O -o build/robot-input robot/robot-input.swift
	swiftc -O -o build/robot-ocr robot/robot-ocr.swift

robot: build robot-tools
	python3 robot/robot.py $(if $(ONLY),--only $(ONLY))

robot-old: robot-tools
	robot/old-commit.sh $(C) $(ONLY)

test:
	checks/run_all.sh
