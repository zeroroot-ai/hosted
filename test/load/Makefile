.PHONY: load-test smoke-load help

help:
	@echo "load-test   — full 100 x 5m against \$$TARGET"
	@echo "smoke-load  — fast 10 x 30s against \$$TARGET (CI-friendly)"

load-test:
	bash 100-concurrent-missions.sh \
	  --target $(TARGET) \
	  --mission-def-id $(MISSION_DEF_ID) \
	  --target-id $(TARGET_ID) \
	  --concurrency 100 \
	  --duration 5m

smoke-load:
	bash 100-concurrent-missions.sh \
	  --target $(TARGET) \
	  --mission-def-id $(MISSION_DEF_ID) \
	  --target-id $(TARGET_ID) \
	  --concurrency 10 \
	  --duration 30s
